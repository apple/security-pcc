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
//  SubrequestProxy.swift
//  PrivateCloudCompute
//
//  Copyright © 2025 Apple Inc. All rights reserved.
//

import OSLog
import Synchronization

private let logger = tc2Logger(forCategory: .connection)

final class SubrequestProxy: PrivateCloudComputeConnectionSubrequestProxy {
    init(
        request: PrivateCloudComputeConnection.Request,
        requestId: UInt64,
        xpcProxy: any XPCRequestProxyProtocol,  // used for sending
        responseDemultiplexer: ResponseDemultiplexer,  // used for receiving
        logPrefix: String
    ) {
        self.request = request
        self.requestId = requestId
        self.xpcProxy = xpcProxy
        self.responseDemultiplexer = responseDemultiplexer
        self.logPrefix = logPrefix
    }

    private let xpcProxy: any XPCRequestProxyProtocol
    private let responseDemultiplexer: ResponseDemultiplexer
    private let request: PrivateCloudComputeConnection.Request
    private let requestId: UInt64
    private let logPrefix: String

    private struct State: Sendable {
        var openSubrequestSent = false
        var closeResponseReceived = false

        /// Holds a reference to a task running a cancellation request.
        var cancelTask: Task<Void, Never>?

        /// Records the fact that the request is now canceled if it hasn't been already. Runs `cancelBlock`
        /// only if the cancel block hasn't been run before.
        ///
        /// Could be called multiple times. `cancelBlock` will be called only on the first call.
        mutating func cancel(cancelBlock: sending @escaping (() async -> Void)) {
            if openSubrequestSent && !closeResponseReceived {
                if cancelTask == nil {
                    cancelTask = Task {
                        await cancelBlock()
                    }
                }
            }
        }

        /// - Throws: CancellationError if the request has been canceled.
        func checkCancellation() throws {
            if cancelTask != nil {
                throw CancellationError()
            }
        }

        /// - Returns: an optional task for the caller to wait for to finish before proceeding. If the response hasn't
        /// been fully received, it will either return a Task for the earlier enqueue cancellation or will run the provided
        /// `cancelBlock` and return a Task running it.
        mutating func finalizeAndCancelIfNeeded(cancelBlock: sending @escaping (() async -> Void)) -> Task<Void, Never>? {
            // At this point `openSubrequest` must have been sent.
            // If we received `subresponseClose`, it means receiving has finished and no cleanup is necessary.
            // If we haven't received `subresponseClose`, it means something went wrong. Adopter may have
            // canceled, or didn't write the request, or didn't read the response, or some error occurred.
            // Either way, since `openSubrequest` has been sent, we should now:
            // 1. send `cancelSubrequest` so the server has an opportunity to abort any work it may still be
            //    doing for this subrequest
            // 2. remember the fact we are sending "cancel" for this subrequest. Although it may not be
            //    necessary since we are wrapping up here.
            // NOTE: we may have already enqueued sending of "cancelSubrequest".

            if openSubrequestSent && !closeResponseReceived {
                // We need to indicate to the caller that they need to send `cancelSubrequest` if it hasn't been done already
                if cancelTask == nil {
                    cancelTask = Task {
                        await cancelBlock()
                    }
                }
            }

            return cancelTask
        }
    }

    private let state = Mutex(State())

    func open() async throws {
        try await xpcProxy.send(message: .openSubrequest(requestId, request.priority, request.opaqueCryptoMaterial))
        state.withLock {
            $0.openSubrequestSent = true
        }
    }

    func close() async {
        logger.log("\(self.logPrefix) close, requestId=\(self.requestId)")
        let cleanupTask = state.withLock {
            $0.finalizeAndCancelIfNeeded {
                logger.log("\(self.logPrefix) will cancel in response to close, requestId=\(self.requestId)")
                await self.sendCancelSubrequest()
            }
        }

        if let cleanupTask {
            await cleanupTask.value
        }
    }

    private func sendCancelSubrequest() async {
        logger.log("\(self.logPrefix) sendCancelSubrequest, requestId=\(self.requestId)")
        defer {
            logger.log("\(self.logPrefix) sendCancelSubrequest finished, requestId=\(self.requestId)")
        }

        // Response demultiplexer needs to know about cancellations so it knows to ignore
        // responses for canceled subrequests.
        self.responseDemultiplexer.cancel(requestId: requestId)

        do {
            try await self.xpcProxy.send(message: .cancelSubrequest(requestId))
        } catch {
            logger.error("\(self.logPrefix) sendCancelSubrequest error, requestId=\(self.requestId), error=\(error)")
        }
    }

    private func checkCloseSubresponseError(status: XPCResponseMessage.SubresponseStatus) throws {
        switch status {
        case .ok:
            break  // no error
        case .internalError:
            throw PrivateCloudComputeError(code: .subrequestResponseIndicatesInternalError)
        case .invalidRequest:
            throw PrivateCloudComputeError(code: .subrequestResponseIndicatesInvalidRequest)
        case .discarded:
            throw PrivateCloudComputeError(code: .subrequestResponseIndicatesDiscarded)
        case .unrecognized:
            throw PrivateCloudComputeError(code: .subrequestResponseIndicatesFailure)
        }
    }

    // MARK: - PrivateCloudComputeConnectionSubrequestProxy

    func send(data: Data) async throws {
        try self.state.withLock {
            try $0.checkCancellation()
        }
        try await self.xpcProxy.send(message: .subrequestData(requestId, data))
    }

    func finishSending() async throws {
        try self.state.withLock {
            try $0.checkCancellation()
        }
        try await self.xpcProxy.send(message: .closeSubrequest(requestId))
    }

    func cancel() {
        // This will be called from subrequest's Writer and Response and it could, and
        // will, be called from both places if adopter has started using them both.

        // If openSubrequest has been sent - we need to send `cancel` to the server
        // regardless whether we already sent everything or not.

        // Also after the subrequest has been canceled, we should be ignoring any server
        // responses tagged for this subrequest. This is done in `next(requestId:)` below.

        self.state.withLock {
            $0.cancel {
                logger.log("\(self.logPrefix) will cancel in response to cancel, requestId=\(self.requestId)")
                await self.sendCancelSubrequest()
            }
        }
    }

    func next() async throws -> Data? {
        try self.state.withLock {
            try $0.checkCancellation()
        }

        while true {
            let message = try await self.responseDemultiplexer.next(requestId: requestId)
            switch message {
            case .data:
                logger.error("\(self.logPrefix) unexpectedly received data instead of subresponseData, requestId=\(self.requestId)")
                continue
            case .openSubresponse:
                continue
            case .subresponseData(_, let data):
                return data
            case .closeSubresponse(_, let status):
                self.state.withLock {
                    $0.closeResponseReceived = true
                }
                try checkCloseSubresponseError(status: status)
                return nil
            }
        }
    }
}
