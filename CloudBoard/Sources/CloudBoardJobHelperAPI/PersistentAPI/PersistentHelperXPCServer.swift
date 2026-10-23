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

package import CloudBoardAsyncXPC
internal import CloudBoardLogging
import os

package actor PersistentHelperXPCServer {
    static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PersistentHelperXPCServer"
    )

    private let listener: CloudBoardAsyncXPCListener
    private weak var delegate: PersistentHelperAPIClientToServerProtocol?
    private var onClientDisconnected: (@Sendable () async -> Void)?

    internal var endpoint: CloudBoardAsyncXPCEndpoint? {
        get async { await self.listener.endpoint }
    }

    /// Test-only passthrough used by `SingleClientListenerWiringTests` to guard the factory wiring.
    internal nonisolated var singleClient: Bool { self.listener.singleClient }

    internal init(
        listener: CloudBoardAsyncXPCListener,
        delegate: PersistentHelperAPIClientToServerProtocol?
    ) {
        self.listener = listener
        self.delegate = delegate
    }
}

extension PersistentHelperXPCServer {
    public static func localListener(serviceName: String, entitlement: String) -> PersistentHelperXPCServer {
        self.init(
            listener: CloudBoardAsyncXPCListener(
                localService: serviceName,
                entitlement: entitlement,
                singleClient: true
            ),
            delegate: nil
        )
    }

    public static func pserverHelperListener() -> PersistentHelperXPCServer {
        self.localListener(
            serviceName: kPersistentServerHelperXPCLocalServiceName,
            entitlement: kPersistentServerHelperXPCLocalServiceEntitlement
        )
    }

    public static func pclientHelperListener() -> PersistentHelperXPCServer {
        self.localListener(
            serviceName: kPersistentClientHelperXPCLocalServiceName,
            entitlement: kPersistentClientHelperXPCLocalServiceEntitlement
        )
    }
}

extension PersistentHelperXPCServer: PersistentHelperAPIServerToClientProtocol {
    public func sendResponse(_ response: PersistentHelperOutboundMessage) async throws {
        // The persistent-helper XPC path is 1:1 (one listener, one peer), so use
        // `sendToAny` — it throws cleanly end-to-end. `broadcast` call
        // used a `withThrowingTaskGroup` that was never iterated, silently
        // swallowing `connection.send` errors. A silent
        // drop at this layer would let the caller commit OHTTP state (nonce
        // advanced) for a chunk the server never received, desyncing the AEAD
        // counters for the rest of the stream.
        //
        // `PersistentHelperOutboundMessage` has `Success == Never, Failure == Never`
        // so overload resolution picks the Never/Never `sendToAny` variant,
        // which posts fire-and-forget (matching broadcast's semantics via
        // `connection.post`) and returns `Void`.
        try await self.listener.sendToAny(response)
    }
}

extension PersistentHelperXPCServer: PersistentHelperAPIServerProtocol {
    public func set(delegate: PersistentHelperAPIClientToServerProtocol) async {
        self.delegate = delegate
    }

    public func setOnClientDisconnected(_ handler: @escaping @Sendable () async -> Void) async {
        self.onClientDisconnected = handler
    }

    public func connect() async {
        await self.listener.set(delegate: self)
        await self.listener.listen(buildMessageHandlerStore: self.configureHandlers)
    }

    internal nonisolated func configureHandlers(_ handlers: inout CloudBoardAsyncXPCConnection.MessageHandlerStore) {
        handlers.register(PersistentHelperXPCClientToServerMessages.Initialize.self) { request in
            Self.logger.debug("Received Initialize XPC message in persistent helper")
            let delegate = try await self.ensureDelegate()
            do {
                try await delegate.initialize(request.params)
            } catch let error as PersistentHelperXPCClientToServerMessages.Initialize.Failure {
                throw error
            } catch {
                throw PersistentHelperXPCClientToServerMessages.Initialize.Failure
                    .unexpectedReportableError(String(reportable: error))
            }
            return ExplicitSuccess()
        }
        handlers.register(PersistentHelperXPCClientToServerMessages.InitializeClient.self) { request in
            Self.logger.debug("Received InitializeClient XPC message in persistent helper")
            let delegate = try await self.ensureDelegate()
            do {
                try await delegate.initializeClient(request.params)
            } catch let error as PersistentHelperXPCClientToServerMessages.InitializeClient.Failure {
                throw error
            } catch {
                throw PersistentHelperXPCClientToServerMessages.InitializeClient.Failure
                    .unexpectedReportableError(String(reportable: error))
            }
            return ExplicitSuccess()
        }
        handlers.register(PersistentHelperXPCClientToServerMessages.SendEncryptedMessage.self) { request in
            Self.logger.debug("Received SendEncryptedMessage XPC message in persistent helper")
            let delegate = try await self.ensureDelegate()
            do {
                try await delegate.sendEncryptedMessage(request.message)
            } catch let error as PersistentHelperXPCClientToServerMessages.SendEncryptedMessage.Failure {
                throw error
            } catch {
                throw PersistentHelperXPCClientToServerMessages.SendEncryptedMessage.Failure
                    .unexpectedReportableError(String(reportable: error))
            }
            return ExplicitSuccess()
        }
        handlers.register(PersistentHelperXPCClientToServerMessages.Teardown.self) { _ in
            Self.logger.debug("Received Teardown XPC message in persistent helper")
            let delegate = try await self.ensureDelegate()
            do {
                try await delegate.teardown()
            } catch let error as PersistentHelperXPCClientToServerMessages.Teardown.Failure {
                throw error
            } catch {
                throw PersistentHelperXPCClientToServerMessages.Teardown.Failure
                    .unexpectedReportableError(String(reportable: error))
            }
            return ExplicitSuccess()
        }
    }

    internal func ensureDelegate() throws -> PersistentHelperAPIClientToServerProtocol {
        guard let delegate = self.delegate else {
            Self.logger.fault("Received message with no delegate set")
            throw PersistentHelperAPIError.noDelegateSet
        }

        return delegate
    }
}

extension PersistentHelperXPCServer: CloudBoardAsyncXPCListenerDelegate {
    package func invalidatedConnection(_: CloudBoardAsyncXPCConnection) async {
        Self.logger.info("Client connection invalidated")
        await self.onClientDisconnected?()
    }
}
