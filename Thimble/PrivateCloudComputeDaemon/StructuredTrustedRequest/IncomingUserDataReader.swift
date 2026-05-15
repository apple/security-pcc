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
//  IncomingUserDataReader.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

internal import CollectionsInternal
import Foundation
import PrivateCloudCompute
import Synchronization

enum IncomingUserData: Equatable {
    /// Used in non multi-turn requests.
    case data(Data)
    /// UInt64 - subrequest id
    case openSubresponse(UInt64)
    /// UInt64 - subrequest id
    case subresponseData(UInt64, Data)
    /// UInt64 - subrequest id
    case closeSubresponse(UInt64, PrivateCloudCompute.XPCResponseMessage.SubresponseStatus)
}

/// "Incoming" meaning from the server.
final class IncomingUserDataReader: Sendable, IncomingUserDataReaderProtocol {
    enum State {
        case waitingForData(Deque<IncomingUserData>, CheckedContinuation<IncomingUserData?, any Error>)
        case waitingForDemand(Deque<IncomingUserData>, finished: Bool, CheckedContinuation<Void, any Error>?)
        case failed(any Error)
        case finished
    }

    let stateLock: Mutex<State>
    static let maxBufferSize = 4

    init() {
        var deque = Deque<IncomingUserData>()
        deque.reserveCapacity(Self.maxBufferSize)
        self.stateLock = Mutex(.waitingForDemand(deque, finished: false, nil))
    }

    private enum ForwardDataAction {
        case succeedNextContinuation(CheckedContinuation<IncomingUserData?, any Error>, IncomingUserData?, CheckedContinuation<Void, any Error>)
        case failForwardContinuation(CheckedContinuation<Void, any Error>, any Error)
        case succeedForwardContinuation(CheckedContinuation<Void, any Error>)
    }

    func forwardData(_ data: IncomingUserData) async throws {
        try await withCheckedThrowingContinuation { (forwardContinuation: CheckedContinuation<Void, any Error>) in
            let action = self.stateLock.withLock { state -> ForwardDataAction? in
                switch state {
                case .waitingForData(let buffer, let nextContinuation):
                    precondition(buffer.isEmpty)
                    state = .waitingForDemand(buffer, finished: false, nil)
                    return .succeedNextContinuation(nextContinuation, data, forwardContinuation)

                case .waitingForDemand(var buffer, finished: false, let existingContinuation):
                    guard existingContinuation == nil else {
                        fatalError("IncomingUserDataReader only supports sequential data forwarding")
                    }
                    buffer.append(data)
                    if buffer.count == Self.maxBufferSize {
                        state = .waitingForDemand(buffer, finished: false, forwardContinuation)
                        return nil
                    } else {
                        state = .waitingForDemand(buffer, finished: false, nil)
                        return .succeedForwardContinuation(forwardContinuation)
                    }

                case .waitingForDemand(_, finished: true, _):
                    fatalError("Sending data after the stream was marked as finished.")

                case .failed(let error):
                    return .failForwardContinuation(forwardContinuation, error)
                case .finished:
                    fatalError("IncomingUserDataReader has already finished")
                }
            }
            switch action {
            case .none:
                break

            case .succeedNextContinuation(let nextContinuation, let data, let forwardContinuation):
                nextContinuation.resume(returning: data)
                forwardContinuation.resume()

            case .failForwardContinuation(let continuation, let error):
                continuation.resume(throwing: error)

            case .succeedForwardContinuation(let continuation):
                continuation.resume()
            }
        }
    }

    func finish(error: (any Error)?) {
        let continuation = self.stateLock.withLock { state -> CheckedContinuation<IncomingUserData?, any Error>? in
            switch state {
            case .waitingForData(let buffer, let nextContinuation):
                precondition(buffer.isEmpty)
                if let error {
                    state = .failed(error)
                } else {
                    state = .finished
                }
                return nextContinuation

            case .waitingForDemand(_, finished: false, .some):
                fatalError("IncomingUserDataReader does not support multiple forward calls at the same time")

            case .waitingForDemand(let buffer, finished: false, .none):
                if let error {
                    state = .failed(error)
                } else {
                    state = .waitingForDemand(buffer, finished: true, nil)
                }
                return nil

            case .failed:
                return nil

            case .finished, .waitingForDemand(_, finished: true, _):
                fatalError("IncomingUserDataReader has already finished")
            }
        }

        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: nil)
        }
    }

    private enum NextAction {
        case succeedNextContinuation(CheckedContinuation<IncomingUserData?, any Error>, IncomingUserData?, unblockUpstream: CheckedContinuation<Void, any Error>?)
        case failNextContinuation(CheckedContinuation<IncomingUserData?, any Error>, any Error)
    }

    func next() async throws -> IncomingUserData? {
        let result = try await withCheckedThrowingContinuation { (nextContinuation: CheckedContinuation<IncomingUserData?, any Error>) in
            let action = self.stateLock.withLock { state -> NextAction? in
                switch state {
                case .waitingForData:
                    fatalError("IncomingUserDataReader does not support multiple next calls at the same time")

                case .waitingForDemand(var buffer, finished: false, let forwardContinuation):
                    guard let next = buffer.popFirst() else {
                        state = .waitingForData(buffer, nextContinuation)
                        return nil
                    }

                    state = .waitingForDemand(buffer, finished: false, nil)
                    return .succeedNextContinuation(nextContinuation, next, unblockUpstream: forwardContinuation)

                case .waitingForDemand(var buffer, finished: true, nil):
                    guard let next = buffer.popFirst() else {
                        state = .finished
                        return .succeedNextContinuation(nextContinuation, nil, unblockUpstream: nil)
                    }
                    state = .waitingForDemand(buffer, finished: true, nil)
                    return .succeedNextContinuation(nextContinuation, next, unblockUpstream: nil)

                case .failed(let error):
                    return .failNextContinuation(nextContinuation, error)

                case .finished:
                    return .succeedNextContinuation(nextContinuation, nil, unblockUpstream: nil)

                case .waitingForDemand(_, finished: true, .some):
                    fatalError("IncomingUserDataReader can not be finished and have a unblock continuation at the same time")
                }
            }
            switch action {
            case .none:
                break

            case .succeedNextContinuation(let continuation, let data, let unblockUpstream):
                continuation.resume(returning: data)
                unblockUpstream?.resume()

            case .failNextContinuation(let continuation, let error):
                continuation.resume(throwing: error)
            }
        }

        return result
    }
}
