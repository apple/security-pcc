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
//  TrustedRequestXPCProxy.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import PrivateCloudCompute
import Synchronization
import os.log

final class TrustedRequestXPCProxy {
    private let logger = tc2Logger(forCategory: .trustedRequestXPCProxy)
    let logPrefix: String

    let outgoingUserDataWriter: OutgoingUserDataWriter

    let incomingUserDataReader: IncomingUserDataReader
    let progressReader: TrustedRequestProgressReader
    let task: Task<Void, any Error>
    let jsonEncoder = JSONEncoder()
    let callIDs = IdentifierSequence()
    let xpcEventsObserver: any TrustedRequestXPCEventsObserver

    let shouldDiscardConsecutiveDiscardableSubrequests = Atomic(false)

    init(
        requestID: UUID,
        outgoingUserDataWriter: OutgoingUserDataWriter,
        incomingUserDataReader: IncomingUserDataReader,
        progressReader: TrustedRequestProgressReader,
        task: Task<Void, any Error>,
        xpcEventsObserver: any TrustedRequestXPCEventsObserver
    ) {
        self.outgoingUserDataWriter = outgoingUserDataWriter
        self.incomingUserDataReader = incomingUserDataReader
        self.progressReader = progressReader
        self.task = task
        self.xpcEventsObserver = xpcEventsObserver
        self.logPrefix = "\(requestID):"
    }

    package func cancelRequestTask(reason: TrustedRequestCancellationReason) {
        self.logger.log("\(self.logPrefix) request task cancelled reason=\(String(describing: reason))")
        self.xpcEventsObserver.willCancel(reason: reason)
        self.task.cancel()
    }
}

extension TrustedRequestXPCProxy: TC2XPCTrustedRequestProtocol {
    func send(data: XPCRequestMessage.Data, completion: @escaping @Sendable (Data?) -> Void) {
        self.logger.log("\(self.logPrefix) xpc.send received data.count=\(data.count)")
        Task {
            do {
                try await self._send(data: data)
                completion(nil)
            } catch let error as PrivateCloudComputeError {
                completion(error.json)
            } catch {
                // Note, _send throws(PrivateCloudComputeError)
                fatalError("Unexpected error given by _send")
            }
        }
    }

    func cancel(completion: @escaping @Sendable () -> Void) {
        self.logger.log("\(self.logPrefix) xpc.cancel received")
        self.cancelRequestTask(reason: .frameworkCancellation)
        completion()
    }

    func close(completion: @escaping @Sendable () -> Void) {
        self.logger.log("\(self.logPrefix) xpc.close received (no-op)")
        completion()
    }

    func next(completion: @escaping @Sendable (XPCResponseMessage.Data?, Data?) -> Void) {
        let callID = self.callIDs.nextIdentifier()
        self.logger.log("\(self.logPrefix) xpc.next received callID=\(callID)")
        Task {
            do {
                let message = try await self._next()
                switch message {
                case .data(let data):
                    self.logger.log("\(self.logPrefix) xpc.next responding callID=\(callID) count=\(data.count)")
                case .openSubresponse(let subrequestId):
                    self.logger.log("\(self.logPrefix) xpc.next responding openSubresponse callID=\(callID) subrequestId=\(subrequestId)")
                case .subresponseData(let subrequestId, let data):
                    self.logger.log("\(self.logPrefix) xpc.next responding callID=\(callID) count=\(data.count) subrequestId=\(subrequestId)")
                case .closeSubresponse(let subrequestId, let status):
                    self.checkForDiscarding(subrequestId: subrequestId, status: status)
                    self.logger.log("\(self.logPrefix) xpc.next responding closeSubresponse callID=\(callID) subrequestId=\(subrequestId) status=\(String(describing: status))")
                case nil:
                    self.logger.log("\(self.logPrefix) xpc.next responding nil callID=\(callID)")
                }
                completion(message?.json, nil)
            } catch let error as PrivateCloudComputeError {
                self.logger.error("\(self.logPrefix) xpc.next responding callID=\(callID) error=\(error)")
                completion(nil, error.json)
            } catch {
                // Note, _next throws(PrivateCloudComputeError)
                fatalError("Unexpected error given by _next")
            }
        }
    }

    func createSubrequest(request: PrivateCloudCompute.XPCSubrequest.Data, completion: @escaping @Sendable (Data?) -> Void) {
        self.logger.log("\(self.logPrefix) xpc.createSubrequest received data.count=\(request.count)")
        do {
            try self._createSubrequest(request: request)
            completion(nil)
        } catch {
            completion(error.json)
        }
    }

    /// Returns `nil` in the completion if there will be no more progress updates.
    func nextProgress(completion: @escaping @Sendable (PrivateCloudCompute.PrivateCloudComputeConnection.Progress.Data?) -> Void) {
        self.logger.log("\(self.logPrefix) xpc.nextProgress received")
        Task {
            let progress = await self.progressReader.next()
            self.logger.log("\(self.logPrefix) xpc.nextProgress responding progress=\(String(describing: progress), privacy: .public)")
            completion(progress?.json)
        }
    }

    private func _send(data: XPCRequestMessage.Data) async throws(PrivateCloudComputeError) {
        guard let message = XPCRequestMessage(json: data) else {
            throw .wrapAny(
                error: DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Failed to convert Data to XPCRequestMessage")
                ))
        }
        do {
            try await self.outgoingUserDataWriter.write(message: .init(message))
        } catch {
            throw .wrapAny(error: error)
        }
    }

    private func _next() async throws(PrivateCloudComputeError) -> XPCResponseMessage? {
        do {
            let data = try await self.incomingUserDataReader.next()
            if let data {
                return XPCResponseMessage(data)
            }
            return nil
        } catch {
            throw .wrapAny(error: error)
        }
    }

    private func _createSubrequest(request: XPCSubrequest.Data) throws(PrivateCloudComputeError) {
        guard let request = XPCSubrequest(json: request) else {
            throw .wrapAny(
                error: DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Failed to convert Data to XPCSubrequest")
                ))
        }

        do {
            try discardSubrequestIfNeeded(request: request)
        } catch {
            self.xpcEventsObserver.createSubrequestFailed(subrequest: request, error: error)
            throw error
        }
    }

    private func discardSubrequestIfNeeded(request: XPCSubrequest) throws(PrivateCloudComputeError) {
        guard request.priority == .discardable else {
            return
        }

        if shouldDiscardConsecutiveDiscardableSubrequests.load(ordering: .acquiring) {
            self.logger.warning("\(self.logPrefix) Discarding a discardable subrequest without sending it to the server due to an earlier discardable subrequest being discarded by the server.")
            throw PrivateCloudComputeError(code: .subrequestDiscardedDueToEarlierDiscard)
        }
    }

    /// Remembers the fact the subrequest has been discarded if it is.
    private func checkForDiscarding(subrequestId: UInt64, status: XPCResponseMessage.SubresponseStatus) {
        if status == .discarded {
            self.logger.warning("\(self.logPrefix) Subrequest has been discarded by the server, subrequestId=\(subrequestId)")
            // Remember the fact, so we know to discard consecutive "discardable" subrequests without even talking to the server.
            self.shouldDiscardConsecutiveDiscardableSubrequests.store(true, ordering: .releasing)
        }
    }
}

extension OutgoingUserData {
    init(_ message: XPCRequestMessage) {
        switch message {
        case .data(let data, let isComplete):
            self = .data(data, isComplete)
        case .openSubrequest(let subrequestId, let priority, let opaqueCryptoMaterials):
            self = .openSubrequest(subrequestId, priority, opaqueCryptoMaterials)
        case .subrequestData(let subrequestId, let data):
            self = .subrequestData(subrequestId, data)
        case .closeSubrequest(let subrequestId):
            self = .closeSubrequest(subrequestId)
        case .cancelSubrequest(let subrequestId):
            self = .cancelSubrequest(subrequestId)
        case .final:
            self = .final
        }
    }
}

extension XPCResponseMessage {
    init(_ incomingUserData: IncomingUserData) {
        switch incomingUserData {
        case .data(let data):
            self = .data(data)
        case .openSubresponse(let subrequestId):
            self = .openSubresponse(subrequestId)
        case .subresponseData(let subrequestId, let data):
            self = .subresponseData(subrequestId, data)
        case .closeSubresponse(let subrequestId, let status):
            self = .closeSubresponse(subrequestId, status)
        }
    }
}
