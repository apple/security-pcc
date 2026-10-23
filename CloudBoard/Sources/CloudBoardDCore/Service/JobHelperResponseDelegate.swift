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
import CloudBoardDomain
import CloudBoardJobHelperAPI
import Foundation
import os
import Synchronization

// cb_jobhelper response to be returned as a response in the InvokeWorkload gRPC call
enum JobHelperInvokeWorkloadResponse: Sendable {
    case responseChunk(ResponseChunk)
    case failureReport(FailureReason)
    case findWorker(query: FindWorkerQuery, negotiate: Negotiate)
    case workerError(UUID)
    case requestExecutionError(RequestExecutionError)
}

// cb_jobhelper response to be returned as a response in the InvokeProxyDialBack gRPC call
enum JobHelperInvokeProxyDialBackResponse {
    case negotiatePickResponse(selectableEnsembles: EnsembleNegotiation)
    case decryptionKey(keyID: Data, Data)
    case workerRequestMessage(Data, isFinal: Bool)
    case workerRequestEOF
}

protocol JobHelperResponseDelegateProtocol: CloudBoardJobHelperAPIClientDelegateProtocol {
    func registerWorker(
        uuid: UUID,
        responseContinuation: AsyncThrowingStream<JobHelperInvokeProxyDialBackResponse, Error>.Continuation
    )
    func waitForLAContextUsedNotification() async throws
    /// Terminates all registered worker dialback streams with the given error.
    func finishAllWorkerContinuations(throwing error: Error)
}

// Delegate to handle messages from cb_jobhelper
final class JobHelperResponseDelegate: JobHelperResponseDelegateProtocol {
    public static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "JobHelperResponseDelegate"
    )

    enum JobHelperResponseDelegateError: Error {
        case delegateDestroyedBeforeLAContextUsed
    }

    private let invokeWorkloadResponseContinuation: AsyncStream<JobHelperInvokeWorkloadResponse>.Continuation
    typealias ProxyDialbackResponseContinuation = AsyncThrowingStream<JobHelperInvokeProxyDialBackResponse, Error>
        .Continuation
    private let workerContinuations: Mutex<[UUID: ProxyDialbackResponseContinuation]> = .init([:])

    private let laContextUsedPromise: Promise<Void, Error> =
        .init(autoFailureIfUnfulfilled: JobHelperResponseDelegateError.delegateDestroyedBeforeLAContextUsed)

    init(invokeWorkloadResponseContinuation: AsyncStream<JobHelperInvokeWorkloadResponse>.Continuation) {
        self.invokeWorkloadResponseContinuation = invokeWorkloadResponseContinuation
    }

    func cloudBoardJobHelperAPIClientSurpriseDisconnect() {
        Self.logger.info("surprise disconnect of job helper client")
        self.invokeWorkloadResponseContinuation.finish()
        self.workerContinuations.withLock {
            for workerContinuation in $0.values {
                workerContinuation.finish(throwing: InvokeProxyDialBackError.invokeWorkloadTerminated)
            }
            $0.removeAll()
        }
    }

    func handleWorkloadResponse(_ response: JobHelperToCloudBoardDaemonMessage) {
        switch response {
        case .responseChunk(let responseChunk):
            self.invokeWorkloadResponseContinuation.yield(.responseChunk(responseChunk))
        case .failureReport(let failureReason):
            self.invokeWorkloadResponseContinuation.yield(.failureReport(failureReason))
        case .findWorker(let query, let negotiate):
            self.invokeWorkloadResponseContinuation.yield(.findWorker(query: query, negotiate: negotiate))
        case .workerNegotiatePickResponse(let uuid, let selectableEnsembles):
            guard let workerContinuation = self.workerContinuations.withLock({ $0[uuid] }) else {
                Self.logger.fault(
                    "Received negotiate pick response for unknown worker ID: \(uuid, privacy: .public). Ignoring."
                )
                return
            }
            workerContinuation.yield(.negotiatePickResponse(selectableEnsembles: selectableEnsembles))
        case .workerDecryptionKey(let uuid, let keyID, let encapsulatedKey):
            guard let workerContinuation = self.workerContinuations.withLock({ $0[uuid] }) else {
                Self.logger.fault(
                    "Received decryption key message for unknown worker ID: \(uuid, privacy: .public). Ignoring."
                )
                return
            }
            workerContinuation.yield(.decryptionKey(keyID: keyID, encapsulatedKey))
        case .workerRequestMessage(let uuid, let data, let isFinal):
            guard let workerContinuation = self.workerContinuations.withLock({ $0[uuid] }) else {
                // This can happen due to a race condition in PCCClient which doesn't affect correctness in any way.
                Self.logger.notice(
                    "Received worker message for unknown worker ID: \(uuid, privacy: .public). Ignoring."
                )
                return
            }
            workerContinuation.yield(.workerRequestMessage(data, isFinal: isFinal))
        case .workerRequestEOF(let uuid):
            // We are not expecting any further messages to be sent to the worker
            if let workerContinuation = self.workerContinuations.withLock({ $0.removeValue(forKey: uuid) }) {
                workerContinuation.yield(.workerRequestEOF)
                workerContinuation.finish()
            } else {
                // This can happen due to a race condition in PCCClient which doesn't affect correctness in any way.
                Self.logger.notice(
                    "Received worker message for unknown worker ID: \(uuid, privacy: .public). Ignoring."
                )
                return
            }
        case .workerError(let uuid):
            // If a continuation exists for the worker where an error occurred
            // we indicate that there would be no further messages
            if let workerContinuation = self.workerContinuations.withLock({ $0.removeValue(forKey: uuid) }) {
                workerContinuation.yield(.workerRequestEOF)
                workerContinuation.finish()
            }

            self.invokeWorkloadResponseContinuation.yield(.workerError(uuid))
        case .jobHelperEOF:
            self.invokeWorkloadResponseContinuation.finish()
        case .usedLAContext:
            self.laContextUsedPromise.succeed()
        case .requestExecutionError(let error):
            self.invokeWorkloadResponseContinuation.yield(.requestExecutionError(error))
        }
    }

    func waitForLAContextUsedNotification() async throws {
        try await Future(self.laContextUsedPromise).valueWithCancellation
    }

    func registerWorker(
        uuid: UUID,
        responseContinuation: ProxyDialbackResponseContinuation
    ) {
        self.workerContinuations.withLock { workerContinuations in
            guard workerContinuations[uuid] == nil else {
                Self.logger.fault(
                    "Received worker registration for \(uuid, privacy: .public) already registered. Ignoring."
                )
                return
            }
            workerContinuations[uuid] = responseContinuation
        }
    }

    func finishAllWorkerContinuations(throwing error: Error) {
        self.workerContinuations.withLock {
            for workerContinuation in $0.values {
                workerContinuation.finish(throwing: error)
            }
            $0.removeAll()
        }
    }
}

struct JobHelperResponseDelegateProvider: CloudBoardJobHelperResponseDelegateProvider {
    func makeDelegate(
        invokeWorkloadResponseContinuation: AsyncStream<JobHelperInvokeWorkloadResponse>.Continuation,
    ) -> JobHelperResponseDelegateProtocol {
        return JobHelperResponseDelegate(
            invokeWorkloadResponseContinuation: invokeWorkloadResponseContinuation,
        )
    }
}
