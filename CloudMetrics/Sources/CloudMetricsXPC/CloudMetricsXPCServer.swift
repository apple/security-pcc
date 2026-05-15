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
//  CloudMetricsXPCServer.swift
//
//
//  Created by Andrea Guzzo on 8/24/22.
//

internal import CloudMetricsAsyncXPC
internal import CloudMetricsConstants
import Foundation
import os

package actor CloudMetricsXPCServer: Sendable {
    private struct CloudMetricsXPCClient {
        var connection: CloudMetricsAsyncXPCConnection
        var clientName: String
    }

    private let listener: CloudMetricsAsyncXPCListener
    private let delegate: CloudMetricsServerProtocol & Sendable
    private let logger: Logger = .init(subsystem: "CloudMetricsXPCServer", category: "ClientB")

    private let connectedClients: OSAllocatedUnfairLock<[CloudMetricsXPCClient]> = .init(initialState: [])

    internal var endpoint: CloudMetricsAsyncXPCEndpoint? {
        get async { await self.listener.endpoint }
    }

    internal init(
        listener: CloudMetricsAsyncXPCListener,
        delegate: CloudMetricsServerProtocol & Sendable
    ) {
        self.listener = listener
        self.delegate = delegate
    }

    private func wrapError(_ error: any Error) throws -> CloudMetricsServiceSuccess {
        switch error {
        case let err as CloudMetricsServiceError:
            switch err {
            case .metricNotAllowed:
                return CloudMetricsServiceSuccess.notAllowed
            default:
                throw err
            }
        default:
            throw error
        }
    }

    private func newHandler<Message: CloudMetricsAsyncXPCMessage>(
        _ handlers: inout CloudMetricsAsyncXPCConnection.MessageHandlerStore,
        message: Message.Type,
        fn: @escaping (Message, MetricsClient) async throws -> Void
    ) {
        handlers.register(message) { message in
            do {
                guard let context = CloudMetricsAsyncXPCContext.context else {
                    throw CloudMetricsServiceError.internalError
                }
                guard let clientName = await context.peerConnection
                    .getEntitlementStringValue(kCloudMetricsXPCServiceEntitlement) else {
                    throw CloudMetricsServiceError.entitlementMissing
                }

                let metricsClient = MetricsClient(name: clientName, remoteProcess: context.peerConnection.name)
                try await fn(message, metricsClient)
            } catch {
                return try await self.wrapError(error) as! Message.Success
            }
            return CloudMetricsServiceSuccess.success as! Message.Success
        }
    }

    private func checkEntitlement() async throws -> String {
        guard let context = CloudMetricsAsyncXPCContext.context else {
            throw CloudMetricsServiceError.internalError
        }
        guard let client = await context.peerConnection.getEntitlementStringValue(kCloudMetricsXPCServiceEntitlement)
        else {
            throw CloudMetricsServiceError.entitlementMissing
        }
        return client
    }

    internal func configureHandlers(_ handlers: inout CloudMetricsAsyncXPCConnection.MessageHandlerStore) {
        self.newHandler(&handlers, message: CloudMetricsServiceMessages.SetConfiguration.self) { message, client in
            try self.delegate.setConfiguration(message.configuration, client: client)
        }

        self.newHandler(&handlers, message: CloudMetricsServiceMessages.IncrementCounter.self) { message, client in
            try self.delegate.incrementCounter(
                message.counter,
                by: message.amount,
                epoch: message.epoch,
                client: client
            )
        }

        self
            .newHandler(
                &handlers,
                message: CloudMetricsServiceMessages.IncrementFloatingPointCounter.self
            ) { message, client in
                try self.delegate.incrementCounter(
                    message.counter,
                    by: message.amount,
                    epoch: message.epoch,
                    client: client
                )
            }

        self.newHandler(&handlers, message: CloudMetricsServiceMessages.ResetCounter.self) { message, client in
            try self.delegate.resetCounter(message.counter, epoch: message.epoch, client: client)
        }

        self
            .newHandler(
                &handlers,
                message: CloudMetricsServiceMessages.ResetCounterWithDoubleValue.self
            ) { message, client in
                try self.delegate.resetCounter(
                    message.counter,
                    initialValue: message.value,
                    epoch: message.epoch,
                    client: client
                )
            }

        self
            .newHandler(
                &handlers,
                message: CloudMetricsServiceMessages.ResetCounterWithIntValue.self
            ) { message, client in
                try self.delegate.resetCounter(
                    message.counter,
                    initialValue: message.value,
                    epoch: message.epoch,
                    client: client
                )
            }

        self.newHandler(&handlers, message: CloudMetricsServiceMessages.RecordDouble.self) { message, client in
            try self.delegate.recordDouble(
                recorder: message.recorder,
                value: message.value,
                epoch: message.epoch,
                client: client
            )
        }

        self.newHandler(&handlers, message: CloudMetricsServiceMessages.RecordInteger.self) { message, client in
            try self.delegate.recordInteger(
                recorder: message.recorder,
                value: message.value,
                epoch: message.epoch,
                client: client
            )
        }

        self.newHandler(&handlers, message: CloudMetricsServiceMessages.RecordNanoseconds.self) { message, client in
            try self.delegate.recordNanoseconds(
                timer: message.timer,
                duration: message.duration,
                epoch: message.epoch,
                client: client
            )
        }

        self.newHandler(&handlers, message: CloudMetricsServiceMessages.RecordHistogramDouble.self) { message, client in
            try self.delegate.recordDouble(
                histogram: message.histogram,
                buckets: message.buckets,
                value: message.value,
                epoch: message.epoch,
                client: client
            )
        }

        self
            .newHandler(
                &handlers,
                message: CloudMetricsServiceMessages.RecordHistogramInteger.self
            ) { message, client in
                try self.delegate.recordInteger(
                    histogram: message.histogram,
                    buckets: message.buckets,
                    value: message.value,
                    epoch: message.epoch,
                    client: client
                )
            }

        self
            .newHandler(
                &handlers,
                message: CloudMetricsServiceMessages.RecordHistogramBuckets.self
            ) { message, client in
                try self.delegate.recordBuckets(
                    histogram: message.histogram,
                    buckets: message.buckets,
                    bucketValues: message.values,
                    sum: message.sum,
                    count: message.count,
                    epoch: message.epoch,
                    client: client
                )
            }

        self.newHandler(&handlers, message: CloudMetricsServiceMessages.RecordSummaryDouble.self) { message, client in
            try self.delegate.recordDouble(
                summary: message.summary,
                quantiles: message.quantiles,
                value: message.value,
                epoch: message.epoch,
                client: client
            )
        }

        self.newHandler(&handlers, message: CloudMetricsServiceMessages.RecordSummaryInteger.self) { message, client in
            try self.delegate.recordInteger(
                summary: message.summary,
                quantiles: message.quantiles,
                value: message.value,
                epoch: message.epoch,
                client: client
            )
        }

        self
            .newHandler(
                &handlers,
                message: CloudMetricsServiceMessages.RecordSummaryQuantiles.self
            ) { message, client in
                try self.delegate.recordQuantiles(
                    summary: message.summary,
                    quantiles: message.quantiles,
                    quantileValues: message.values,
                    sum: message.sum,
                    count: message.count,
                    epoch: message.epoch,
                    client: client
                )
            }
    }

    package func run() async throws {
        await self.listener.set(delegate: self)
        await self.listener.listen(buildMessageHandlerStore: self.configureHandlers)
        do {
            // Wait for task cancellation
            while true {
                try await Task.sleep(for: .seconds(60 * 60))
            }
        } catch {
            await self.listener.cancel()
            throw error
        }
    }
}

extension CloudMetricsXPCServer {
    package static func anonymousListener(delegate: CloudMetricsServerProtocol & Sendable) -> CloudMetricsXPCServer {
        self.init(
            listener: CloudMetricsAsyncXPCListener(localService: nil, entitlement: nil),
            delegate: delegate
        )
    }

    package static func localListener(
        delegate: CloudMetricsServerProtocol & Sendable,
        xpcServiceName: String
    ) -> CloudMetricsXPCServer {
        self.init(
            listener: CloudMetricsAsyncXPCListener(
                localService: xpcServiceName,
                entitlement: nil
            ),
            delegate: delegate
        )
    }
}

extension CloudMetricsXPCServer: CloudMetricsAsyncXPCListenerDelegate {
    func clientConnected(_ connection: CloudMetricsAsyncXPC.CloudMetricsAsyncXPCConnection) async {
        guard let clientName = await connection.getEntitlementStringValue(kCloudMetricsXPCServiceEntitlement) else {
            self.logger.error(
                """
                Connection denied due to missing entitlement. \
                connnection_name=\(connection.name, privacy: .public). \
                entitlement=\(kCloudMetricsXPCServiceEntitlement, privacy: .public)
                """
            )
            await connection.cancel()
            return
        }
        self.logger.log("Client connected. client=\(clientName)")

        let cloudMetricsXPCClient = CloudMetricsXPCClient(connection: connection, clientName: clientName)
        self.connectedClients.withLock { clients in
            clients.append(cloudMetricsXPCClient)
        }

        self.delegate.clientConnected(client: .init(name: clientName, remoteProcess: connection.name))
    }

    func clientDisconnected(_ connection: CloudMetricsAsyncXPC.CloudMetricsAsyncXPCConnection) async {
        self.connectedClients.withLock { clients in
            if let index = clients.firstIndex(where: { $0.connection.name == connection.name }) {
                let client = clients.remove(at: index)
                self.logger.log("Client disconnected. client=\(client.clientName)")
                self.delegate.clientDisconnected(client: .init(
                    name: client.clientName,
                    remoteProcess: client.connection.name
                ))
            } else {
                self.logger.error(
                    """
                    Client disconnected but was not being tracked. \
                    connection_name=\(connection.name, privacy: .public)
                    """
                )
            }
        }
    }
}
