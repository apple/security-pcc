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

import CloudBoardDomain
import CloudBoardJobAPI
import CloudBoardLogging
import Foundation
import os

/// A lightweight proxy actor that implements the `ManagedCloudAppProtocol` to find worker nodes.
///
/// `TrampolineApp` serves as a trusted proxy app in the CloudBoard system, designed to receive parameters
/// and immediately request a worker node to handle the actual workload processing.
///
/// ## Error Handling
///
/// The trampoline app can encounter several error conditions during operation:
///
/// ### TrampolineAppError Cases
///
/// - **unsupportedOperation**: Thrown when attempting to call methods that are not supported by the trampoline
///   implementation since it runs in request and response bypass mode. This includes:
///   - `provideInput(_:)`: Input provision is handled by worker nodes, since trampoline
///   - `openClientSubrequest(subrequestId:cryptoMaterialHandles:isDiscardable:)`: Subrequests are not supported
///   - `subrequestPayloadChunk(subrequestId:chunk:)`: Payload chunks are not supported
///   - `closeClientSubrequest(subrequestId:)`: Closing subrequests is not supported
///   - `cancelClientSubrequest(subrequestId:)`: Canceling subrequests are not supported
///
/// - **parametersReceivedTwice**: Thrown when `parameters(_:)` is called more than once on the same trampoline
///   instance. The trampoline is designed to handle only a single parameter set per instance.
///
/// - **workerIDMismatch(expected:received:)**: Thrown when `workerFound(workerID:info:spanID:)` is called
///   with a worker ID that doesn't match the expected worker ID generated during initialization.
///
/// ### Stream Termination
///
/// The response stream (`responseStream`) will be terminated with an error in the following cases:
/// - Any of the `TrampolineAppError` cases above
/// - Errors passed to `endOfInput(error:)` method
/// - Normal completion when worker is found and handoff is complete
actor TrampolineApp: ManagedCloudAppProtocol {
    static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "TrampolineApp"
    )

    let cloudAppName: String
    let workerID: UUID
    let remotePID: Int? = nil
    var abandoned: Bool = false
    private var workerDialbackCompleted = false

    private nonisolated let (cloudAppResponseStream, cloudAppResponseContinuation) = AsyncThrowingStream<
        CloudAppResponse,
        any Error
    >.makeStream()

    nonisolated var responseStream: AsyncThrowingStream<CloudAppResponse, any Error> {
        self.cloudAppResponseStream
    }

    var parameterData: ParametersData? = nil

    init(cloudAppName: String) {
        self.cloudAppName = cloudAppName
        self.workerID = .init()
    }

    func warmup(info _: ManagedWarmupInfo) async throws {
        Self.logger.log("Received warmup")
    }

    func parameters(_ parametersData: ParametersData) async throws {
        guard self.parameterData == nil else {
            self.cloudAppResponseContinuation.finish(throwing: TrampolineAppError.parametersReceivedTwice)
            return
        }
        Self.logger.log("Received parameters. Requesting worker node.")
        self.parameterData = parametersData
        let findWorkerQuery = FindWorkerQuery(
            workerID: self.workerID,
            serviceName: parametersData.plaintextMetadata.workloadType,
            routingParameters: parametersData.plaintextMetadata.workloadParameters,
            effort: nil,
            reuseTarget: nil,
            responseBypass: true,
            forwardRequestChunks: true,
            isFinal: true,
            spanID: parametersData.traceContext.spanID,
            isDiscardable: false
        )
        self.cloudAppResponseContinuation.yield(.findWorker(findWorkerQuery, nil, []))
    }

    func teardown() async throws {
        Self.logger.log("Received teardown")
        self.cloudAppResponseContinuation.finish()
    }

    func abandon() async throws {
        Self.logger.log("Received abandon")
        self.abandoned = true
        self.cloudAppResponseContinuation.finish()
    }

    func run() async throws {
        // No op
    }

    func provideInput(_: Data) async throws {
        self.cloudAppResponseContinuation.finish(throwing: TrampolineAppError.unsupportedOperation)
    }

    func openClientSubrequest(
        subrequestId _: UInt64,
        cryptoMaterialHandles _: [CryptoMaterialHandle],
        isDiscardable _: Bool
    ) async throws {
        self.cloudAppResponseContinuation.finish(throwing: TrampolineAppError.unsupportedOperation)
    }

    func subrequestPayloadChunk(subrequestId _: UInt64, chunk _: Data) async throws {
        self.cloudAppResponseContinuation.finish(throwing: TrampolineAppError.unsupportedOperation)
    }

    func closeClientSubrequest(subrequestId _: UInt64) async throws {
        self.cloudAppResponseContinuation.finish(throwing: TrampolineAppError.unsupportedOperation)
    }

    func cancelClientSubrequest(subrequestId _: UInt64) async throws {
        self.cloudAppResponseContinuation.finish(throwing: TrampolineAppError.unsupportedOperation)
    }

    func endOfInput(error: (any Error)?) async throws {
        if let error {
            self.cloudAppResponseContinuation.finish(throwing: error)
        }
    }

    func workerFound(workerID: UUID, info _: WorkerFoundInfo, spanID _: UInt64?) async throws {
        guard workerID == self.workerID else {
            self.cloudAppResponseContinuation.finish(throwing: TrampolineAppError.workerIDMismatch(
                expected: self.workerID,
                received: workerID
            ))
            return
        }
        Self.logger.log("Worker found. Sending close on dialback stream.")
        self.cloudAppResponseContinuation.yield(.workerRequestEOF(workerID, false))
    }

    // Called when the dialback stream ends (workerResponseEOF). This arrives after
    // workerResponseSummary but acts as a fallback if the summary was never delivered
    // (e.g. ROPES error path). completeJob() is idempotent so the duplicate call is safe.
    func workerResponseMessage(workerID _: UUID, data: Data?, isFinal: Bool) async throws {
        guard data == nil, isFinal else {
            self.cloudAppResponseContinuation.finish(throwing: TrampolineAppError.unsupportedOperation)
            return
        }
        self.completeJob()
    }

    // Called when ROPES sends its close message on the dialback stream. This is the
    // primary signal that the close exchange is complete — we can now finish the job.
    func workerResponseSummary(workerID _: UUID, status _: WorkerResponseStatus) async throws {
        Self.logger.log("Received close response from ROPES. Completing trampoline job.")
        self.completeJob()
    }

    // This is not expected to be invoked, because Trampoline does not opt in delayedTerminationOnFailure
    func workerFailure(workerID _: UUID, rawROPESCode _: UInt32, ropesMessage _: String?) async throws {
        Self.logger.error("Unexpected to receive worker failure.")
        self.cloudAppResponseContinuation.finish(throwing: TrampolineAppError.unsupportedOperation)
    }

    private func completeJob() {
        guard !self.workerDialbackCompleted else { return }
        self.workerDialbackCompleted = true
        self.cloudAppResponseContinuation.yield(.endOfResponse)
        self.cloudAppResponseContinuation.yield(.endJob)
        self.cloudAppResponseContinuation.yield(.appTermination(TerminationMetadata(statusCode: 0)))
        self.cloudAppResponseContinuation.finish()
    }

    func configureApplicationDataChunking(config _: ApplicationDataChunkingConfiguration) async throws {
        // No op
        Self.logger.debug("Ignoring data chunking configuration")
    }

    func clientDiagnosticsSharingOptIn(_: Bool) async throws {
        // No op
        Self.logger.debug("Ignoring client diagnostics sharing opt-in")
    }

    func sendPersistentServiceResponse(_: PersistentService.Response) async throws {
        // No op - trampoline doesn't handle persistent service responses
    }

    /// Errors that can be thrown by the `TrampolineApp` during operation.
    ///
    /// These errors indicate various failure modes specific to the trampoline's lightweight proxy behavior.
    enum TrampolineAppError: ReportableError {
        var publicDescription: String {
            switch self {
            case .unsupportedOperation: "Unsupported operation"
            case .parametersReceivedTwice: "Parameters received twice"
            case .workerIDMismatch(
                let expected,
                let received
            ): "Worker ID mismatch: expected \(expected), received \(received)"
            }
        }

        /// Indicates that an operation was attempted that is not supported by the trampoline implementation.
        ///
        /// The trampoline app is designed as a lightweight proxy that delegates actual work to worker nodes.
        /// Many operations that would be valid on a full cloud app implementation are intentionally
        /// unsupported on the trampoline to maintain its focused role.
        case unsupportedOperation

        /// Indicates that parameters were provided to the trampoline more than once.
        ///
        /// Each trampoline instance is designed to handle exactly one parameter set and immediately
        /// request a worker node. Calling `parameters(_:)` multiple times violates this contract.
        case parametersReceivedTwice

        /// Indicates that a worker was found with an unexpected worker ID.
        ///
        /// The trampoline generates a unique worker ID when initialized and expects any worker
        /// found notifications to match this ID. This error occurs when there's a mismatch,
        /// which could indicate a routing or coordination issue in the CloudBoard system.
        ///
        /// - Parameters:
        ///   - expected: The worker ID that the trampoline was expecting
        ///   - received: The worker ID that was actually received
        case workerIDMismatch(expected: UUID, received: UUID)
    }
}
