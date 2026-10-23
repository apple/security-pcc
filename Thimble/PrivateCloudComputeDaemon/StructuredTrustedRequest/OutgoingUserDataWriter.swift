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

//
//  OutgoingUserDataWriter.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

internal import CollectionsInternal
import Foundation
import PrivateCloudCompute
import Synchronization
import os.log

private let logger = Logger(for: .trustedRequest)

/// Corresponds to `XPCRequestMessage`. See `XPCRequestMessage`'s documentation.
enum OutgoingUserData: Equatable {
    /// Used for non multi-turn request.
    case data(XPCRequestMessage.DataPayload)

    /// Used in multi-turn requests to mark the beginning of a new subrequest.
    case openSubrequest(XPCRequestMessage.OpenSubrequestPayload)
    /// Used in multi-turn requests for the actual subrequest's data.
    case subrequestData(XPCRequestMessage.SubrequestDataPayload)
    /// Used in multi-turn requests to mark the end of a new subrequest.
    case closeSubrequest(XPCRequestMessage.CloseSubrequestPayload)
    /// Used in multi-turn requests to signal a cancellation of subrequest to the server.
    case cancelSubrequest(XPCRequestMessage.CancelSubrequestPayload)

    /// Used in multi-turn requests to indicate completion of the outer request. Means there will
    /// be no new subrequests after this point.
    /// Also could be used for non multi-turn requests, when adopter uses streaming API, to indicate
    /// the end of it.
    case final

    var isComplete: Bool {
        switch self {
        case .data(let payload):
            return payload.isComplete
        case .final:
            return true
        default:
            return false
        }
    }
}

/// "Outgoing" meaning going to the server. The data is coming from an adopter via PCC framework.
final class OutgoingUserDataWriter {
    private struct StateMachine {
        enum State {
            case waitingForMoreDataToSend(CheckedContinuation<(CheckedContinuation<Void, any Error>, OutgoingUserData), any Error>, waiterID: Int)
            case bufferingOutbound(Deque<(CheckedContinuation<Void, any Error>, OutgoingUserData)>)
            case cancelled(any Error)
        }

        var state: State = .bufferingOutbound(.init())

        enum SendAction {
            case succeedContinuation(CheckedContinuation<(CheckedContinuation<Void, any Error>, OutgoingUserData), any Error>)
            case failWrite(any Error)
            case none
        }

        mutating func sendElement(_ element: OutgoingUserData, continuation: CheckedContinuation<Void, any Error>) -> SendAction {
            switch self.state {
            case .waitingForMoreDataToSend(let writeContinuation, _):
                self.state = .bufferingOutbound(.init())
                return .succeedContinuation(writeContinuation)

            case .cancelled(let error):
                return .failWrite(error)

            case .bufferingOutbound(var buffer):
                buffer.append((continuation, element))
                self.state = .bufferingOutbound(buffer)
                return .none
            }
        }

        enum NextOutgoingAction {
            case succeedContinuation(CheckedContinuation<Void, any Error>, OutgoingUserData)
            case cancel(any Error, [CheckedContinuation<Void, any Error>])
            case wait
        }

        mutating func nextOutgoingElement(
            _ continuation: CheckedContinuation<(CheckedContinuation<Void, any Error>, OutgoingUserData), any Error>,
            waiterID: Int
        ) -> NextOutgoingAction {
            switch self.state {
            case .bufferingOutbound(var deque):
                if Task.isCancelled {
                    // fail all writes
                    let error = CancellationError()
                    self.state = .cancelled(error)
                    return .cancel(error, deque.map { $0.0 })
                }

                if let first = deque.popFirst() {
                    self.state = .bufferingOutbound(deque)
                    return .succeedContinuation(first.0, first.1)
                }

                self.state = .waitingForMoreDataToSend(continuation, waiterID: waiterID)
                return .wait

            case .cancelled(let error):
                return .cancel(error, [])

            case .waitingForMoreDataToSend:
                fatalError("`nextOutgoingElement` can not be called multiple times at once")
            }
        }

        enum CancelAction {
            case none
            case cancel(any Error, CheckedContinuation<(CheckedContinuation<Void, any Error>, OutgoingUserData), any Error>)
        }

        mutating func cancelNextOutgoingWaiter(waiterID: Int) -> CancelAction {
            switch self.state {
            case .bufferingOutbound, .cancelled:
                return .none

            case .waitingForMoreDataToSend(let continuation, let storedWaiterID):
                if storedWaiterID == waiterID {
                    self.state = .cancelled(CancellationError())
                    return .cancel(CancellationError(), continuation)
                } else {
                    return .none
                }
            }
        }

        enum CancelWriterAction {
            case cancelOutgoingContinuation(CheckedContinuation<(CheckedContinuation<Void, any Error>, OutgoingUserData), any Error>)
            case cancelUserContinuations([CheckedContinuation<Void, any Error>])
        }

        mutating func cancelAllWrites(error: any Error) -> CancelWriterAction? {
            switch self.state {
            case .waitingForMoreDataToSend(let continuation, waiterID: _):
                self.state = .cancelled(error)
                return .cancelOutgoingContinuation(continuation)

            case .bufferingOutbound(let buffer):
                self.state = .cancelled(error)
                let continuations = Array(buffer.lazy.map { $0.0 })
                return .cancelUserContinuations(continuations)

            case .cancelled:
                return .none
            }

        }
    }

    private let stateLock: Mutex<StateMachine> = Mutex(StateMachine())
    private let waiterIDGenerator = IdentifierSequence()
    /// Closure to be called on `cancelAllWrites`.
    private let onCancelAllWrites: Mutex<(@Sendable (any Error) -> Void)?> = Mutex(nil)
}

extension OutgoingUserDataWriter: OutgoingUserDataWriterProtocol {
    func withNextOutgoingElement<Result>(_ closure: (OutgoingUserData) async throws -> Result) async throws -> Result {
        let waiterID = self.waiterIDGenerator.nextIdentifier()

        return try await withTaskCancellationHandler {
            let (writeDoneContinuation, element) = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<(CheckedContinuation<Void, any Error>, OutgoingUserData), any Error>) in

                let action = self.stateLock.withLock {
                    $0.nextOutgoingElement(continuation, waiterID: waiterID)
                }

                switch action {
                case .succeedContinuation(let writeDoneContinuation, let element):
                    continuation.resume(returning: (writeDoneContinuation, element))
                case .cancel(let error, let writeContinuations):
                    continuation.resume(throwing: error)
                    for continuation in writeContinuations {
                        continuation.resume(throwing: error)
                    }
                case .wait:
                    break
                }
            }

            do {
                let result = try await closure(element)
                writeDoneContinuation.resume()
                return result
            } catch {
                writeDoneContinuation.resume(throwing: error)
                throw error
            }
        } onCancel: {
            let cancelAction = self.stateLock.withLock { $0.cancelNextOutgoingWaiter(waiterID: waiterID) }

            switch cancelAction {
            case .cancel(let error, let continuation):
                continuation.resume(throwing: error)
            case .none:
                break
            }

            self.onCancelAllWrites.withLock {
                $0 = nil
            }
        }
    }

    func cancelAllWrites(error: any Error) {
        let action = self.stateLock.withLock { $0.cancelAllWrites(error: error) }
        logger.log("OutgoingUserDataWriter.cancelAllWrites, error=\(error), action=\(String(describing: action))")

        switch action {
        case .cancelOutgoingContinuation(let continuation):
            continuation.resume(throwing: error)
        case .cancelUserContinuations(let continuations):
            for continuation in continuations {
                continuation.resume(throwing: error)
            }
        case .none:
            break
        }

        onCancelAllWrites.withLock {
            $0?(error)
            $0 = nil
        }
    }

    func write(message element: OutgoingUserData) async throws {
        try await withCheckedThrowingContinuation { (writeDoneContinuation: CheckedContinuation<Void, any Error>) in
            let action = self.stateLock.withLock { state in
                state.sendElement(element, continuation: writeDoneContinuation)
            }

            switch action {
            case .succeedContinuation(let writeContinuation):
                writeContinuation.resume(returning: (writeDoneContinuation, element))
            case .failWrite(let error):
                writeDoneContinuation.resume(throwing: error)
            case .none:
                break
            }
        }
    }

    func registerCancelAllWritesClosure(_ closure: @escaping @Sendable (any Error) -> Void) {
        self.onCancelAllWrites.withLock {
            $0 = closure
        }
    }
}
