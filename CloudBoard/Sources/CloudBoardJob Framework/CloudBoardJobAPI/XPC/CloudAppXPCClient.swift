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

package import CloudBoardAsyncXPC
package import CloudBoardDomain
internal import CloudBoardOSActivity
import Foundation
import os

package actor CloudAppXPCClient {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CloudAppXPCClient"
    )

    private var connection: CloudBoardAsyncXPCConnection?
    private let enforceCloudAppEntitlements: Bool
    private var responseHandler: CloudBoardJobAPICloudAppResponseHandlerProtocol

    package init(
        connection: CloudBoardAsyncXPCConnection,
        // this would only be false in unit tests
        enforceCloudAppEntitlements: Bool = true,
        responseHandler: CloudBoardJobAPICloudAppResponseHandlerProtocol
    ) async {
        self.enforceCloudAppEntitlements = enforceCloudAppEntitlements
        self.responseHandler = responseHandler
        await self.connection = connection
            .handleConnectionInvalidated { [weak self] _ in
                await self?.surpriseDisconnect()
            }
    }
}

extension CloudAppXPCClient {
    /// Create a client connection to the XPC service
    /// - Parameters:
    ///   - machServiceName: mach service name of the CloudApp
    ///   - uuid: uuid of the specific CloudApp instance to connect to
    /// - Returns: `CloudBoardJobAPIXPCClient`
    package static func localConnectionWithUUID(
        machServiceName: String,
        uuid: UUID,
        responseHandler: CloudBoardJobAPICloudAppResponseHandlerProtocol
    ) async
    -> CloudAppXPCClient {
        await self.init(
            connection: .connect(to: machServiceName, withUUID: uuid),
            enforceCloudAppEntitlements: true,
            responseHandler: responseHandler
        )
    }
}

extension CloudAppXPCClient {
    struct SurpriseDisconnect: Error {}
    private func surpriseDisconnect() async {
        if self.connection != nil {
            self.connection = nil
            self.responseHandler.disconnected(error: SurpriseDisconnect())
        }
    }

    package func disconnect() async {
        if let connection = self.connection {
            self.connection = nil
            await connection.handleConnectionInvalidated(handler: nil)
            await connection.cancel()
            self.responseHandler.disconnected(error: nil)
        }
    }
}

/// Implements the outbound (calling the CloudApp) XPC interface.
extension CloudAppXPCClient: CloudBoardJobAPIClientToServerProtocol {
    package func warmup(info: ManagedWarmupInfo) async throws {
        /// We always require a warmup
        await self.connection?.activate(buildMessageHandlerStore: self.configureHandlers)
        _ = try await self.connection?.send(JobHelperToManagedAppXPCMessages.Warmup(info: info))
    }

    package func receiveParameters(parametersData: ParametersData) async throws {
        try await self.connection?.send(parametersData)
    }

    package func provideInput(_ data: Data) async throws {
        let requestChunk = CloudBoardJobAPIXPCClientToServerMessage.RequestChunk(
            data: data
        )
        try await self.sendWorkloadRequestMessage(.requestChunk(requestChunk))
    }

    package func openClientSubrequest(
        subrequestID: UInt32,
        cryptoMaterialHandles: [CloudBoardDomain.CryptoMaterialHandle],
        isDiscardable: Bool
    ) async throws {
        try await self.sendWorkloadRequestMessage(
            .openClientSubrequest(
                .init(
                    clientSubrequestID: subrequestID,
                    cryptoMaterialHandles: cryptoMaterialHandles,
                    isDiscardable: isDiscardable
                )
            )
        )
    }

    package func receiveSubrequestPayload(subrequestID: UInt32, payload: Data) async throws {
        try await self.sendWorkloadRequestMessage(
            .subrequestPayloadChunk(.init(clientSubrequestID: subrequestID, chunk: payload))
        )
    }

    package func closeClientSubrequest(subrequestID: UInt32) async throws {
        try await self.sendWorkloadRequestMessage(.closeClientSubrequest(.init(clientSubrequestID: subrequestID)))
    }

    package func cancelClientSubrequest(subrequestID: UInt32) async throws {
        try await self.sendWorkloadRequestMessage(.cancelClientSubrequest(.init(clientSubrequestID: subrequestID)))
    }

    private func sendWorkloadRequestMessage(
        _ request: CloudBoardJobAPIXPCClientToServerMessage.InvokeWorkloadRequest
    ) async throws {
        try await self.connection?.send(request)
    }

    package func receiveWorkerFoundEvent(workerID: UUID, info: WorkerFoundInfo) async throws {
        try await self.sendWorkloadRequestMessage(
            .receiveWorkerFoundEvent(.init(workerID: workerID, info: info))
        )
    }

    package func receiveWorkerMessage(workerID: UUID, _ message: WorkerResponseMessage) async throws {
        let workerResponseMessage = CloudBoardJobAPIXPCClientToServerMessage.WorkerResponse(
            workerID: workerID,
            message: message
        )
        try await self.sendWorkloadRequestMessage(.receiveWorkerMessage(workerResponseMessage))
    }

    package func receiveWorkerResponseSummary(workerID: UUID, status: WorkerResponseStatus) async throws {
        let workerResponseSummary = CloudBoardJobAPIXPCClientToServerMessage.WorkerResponseSummary(
            workerID: workerID,
            status: status
        )
        try await self.sendWorkloadRequestMessage(.receiveWorkerResponseSummary(workerResponseSummary))
    }

    package func receiveWorkerEOF(workerID: UUID) async throws {
        let workerEOF = CloudBoardJobAPIXPCClientToServerMessage.WorkerEOF(
            workerID: workerID
        )
        try await self.sendWorkloadRequestMessage(.receiveWorkerEOF(workerEOF))
    }

    package func teardown() async throws {
        try await self.connection?.send(CloudBoardJobAPIXPCClientToServerMessage.Teardown())
    }

    package func endOfInput() async throws {
        try await self.sendWorkloadRequestMessage(.endOfInput)
    }

    package func configureApplicationDataChunking(config: ApplicationDataChunkingConfiguration) async throws {
        try await self.sendWorkloadRequestMessage(.configureApplicationDataChunking(config))
    }
}

extension CloudAppXPCClient {
    func handleResponseChunk(chunk: DataMessage) {
        self.responseHandler.handleResponseChunk(chunk.data)
    }

    func handleEndOfResponse(_: EndOfResponse) async throws -> ExplicitSuccess {
        try await self.responseHandler.handleEndOfResponse()
        return ExplicitSuccess()
    }

    func handleRequestExecutionError(error: CloudAppToJobHelperRequestExecutionError) async throws
    -> ExplicitSuccess {
        try await self.responseHandler.handleRequestExecutionError(error)
        return ExplicitSuccess()
    }

    func handleInternalError(message _: ManagedAppToJobHelperXPCMessages.InternalError) async throws
    -> ExplicitSuccess {
        try await self.responseHandler.handleInternalError()
        return ExplicitSuccess()
    }

    func handleEndJob(_: ManagedAppToJobHelperXPCMessages.EndJob) async throws -> ExplicitSuccess {
        try await self.responseHandler.handleEndJob()
        return ExplicitSuccess()
    }

    func handleFindWorker(_ findWorkerMessage: FindWorkerMessage) async throws -> ExplicitSuccess {
        guard let xpcConnection = CloudBoardAsyncXPCContext.context?.peerConnection else {
            // This is a programming error, there is no condition where we would get a message but not have
            // a `peerConnection` available.
            assertionFailure("xpcConnection not available")
            Self.logger.error("xpcConnection not available")
            return ExplicitSuccess()
        }
        let hasEntitlement = await xpcConnection.hasEntitlement(kCloudBoardJobAPIOutboundPCCRequestEntitlement)
        if self.enforceCloudAppEntitlements {
            if !hasEntitlement {
                Self.logger.error("CloudApp not entitled to make outbound pcc requests but this check is disabled")
            }

        } else {
            guard hasEntitlement else {
                Self.logger.error("CloudApp not entitled to make outbound pcc requests")
                fatalError("CloudApp not entitled to make outbound pcc requests")
            }
        }
        try await self.responseHandler.handleFindWorker(findWorkerMessage)
        return ExplicitSuccess()
    }

    func handleWorkerRequestMessage(_ workerRequestMessage: WorkerRequestMessage) {
        self.responseHandler.handleWorkerRequestMessage(workerRequestMessage)
    }

    func handleWorkerEOF(workerEOF: WorkerEOF) {
        self.responseHandler.handleWorkerEOF(workerEOF)
    }

    func handleFinaliseRequestExecutionLog(_: FinalizeRequestExecutionLog) {
        self.responseHandler.handleFinaliseRequestExecutionLog()
    }

    package func configureKeyDerivationHandler(
        _ handler: @escaping @Sendable (CloudAppToJobHelperDeriveKeyMessage) async throws
            -> CloudAppToJobHelperDeriveKeyMessage.Success
    ) async {
        await self.connection?.registerHandler(CloudAppToJobHelperDeriveKeyMessage.self, handler: handler)
    }

    package func configureSealedKeyDerivationHandler(
        _ handler: @escaping @Sendable (CloudAppToJobHelperDeriveSealedKeyMessage) async throws
            -> CloudAppToJobHelperDeriveSealedKeyMessage.Success
    ) async {
        await self.connection?.registerHandler(CloudAppToJobHelperDeriveSealedKeyMessage.self, handler: handler)
    }
}

extension CloudAppXPCClient {
    private func configureHandlers(
        _ handlers: inout CloudBoardAsyncXPCConnection.MessageHandlerStore
    ) {
        handlers.register(DataMessage.self, handler: self.handleResponseChunk)
        handlers.register(ManagedAppToJobHelperXPCMessages.InternalError.self, handler: self.handleInternalError)
        handlers.register(CloudAppToJobHelperRequestExecutionError.self, handler: self.handleRequestExecutionError)
        handlers.register(EndOfResponse.self, handler: self.handleEndOfResponse)
        handlers.register(ManagedAppToJobHelperXPCMessages.EndJob.self, handler: self.handleEndJob)
        handlers.register(FindWorkerMessage.self, handler: self.handleFindWorker)
        handlers.register(WorkerRequestMessage.self, handler: self.handleWorkerRequestMessage)
        handlers.register(WorkerEOF.self, handler: self.handleWorkerEOF)
        handlers.register(FinalizeRequestExecutionLog.self, handler: self.handleFinaliseRequestExecutionLog)
    }
}
