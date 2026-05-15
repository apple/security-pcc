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
import CloudBoardCommon
package import CloudBoardDomain
import Foundation

package enum JobHelperToCloudBoardDaemonMessage: CloudBoardAsyncXPCByteBufferMessage, Sendable, Equatable {
    // There is no particularly good reason for the message to require an ExplicitSuccess,
    // however we use the same protocol on both ends of the XPC connection, and while the
    // sender needs to be async to perform the send, the handler should not be to avoid
    // message reordering through scheduling. But it is now, due to `JobHelperResponseDelegate`,
    // so we rely on the sender waiting for responses before sending more messages to avoid
    // reordering.
    public typealias Success = Never
    public typealias Failure = Never

    case responseChunk(ResponseChunk)
    case failureReport(FailureReason)
    case findWorker(query: FindWorkerQuery, negotiate: Negotiate)
    case workerNegotiatePickResponse(UUID, selectableEnsembles: EnsembleNegotiation)
    case workerDecryptionKey(UUID, keyID: Data, Data)
    case workerRequestMessage(UUID, Data, isFinal: Bool)
    case workerRequestEOF(UUID)
    case workerError(UUID)
    case jobHelperEOF
    case usedLAContext
    case requestExecutionError(RequestExecutionError)

    public static func == (
        lhs: JobHelperToCloudBoardDaemonMessage,
        rhs: JobHelperToCloudBoardDaemonMessage
    ) -> Bool {
        switch lhs {
        case .responseChunk(let lhsChunk):
            if case .responseChunk(let rhsChunk) = rhs {
                return lhsChunk == rhsChunk
            }
            return false
        case .failureReport(let lhsReason):
            if case .failureReport(let rhsReason) = rhs {
                return lhsReason == rhsReason
            }
            return false
        case .workerDecryptionKey(let lhsWorkerID, let lhsKeyID, let lhsKey):
            if case .workerDecryptionKey(let rhsWorkerID, let rhsKeyID, let rhsKey) = rhs {
                return lhsWorkerID == rhsWorkerID && lhsKeyID == rhsKeyID && lhsKey == rhsKey
            }
            return false
        case .findWorker(let lhsQuery, let lhsNegotiate):
            if case .findWorker(let rhsQuery, let rhsNegotiate) = rhs {
                return lhsQuery == rhsQuery && lhsNegotiate == rhsNegotiate
            }
            return false
        case .workerNegotiatePickResponse(let lhsWorkerID, let lhsSelectableEnsembles):
            if case .workerNegotiatePickResponse(let rhsWorkerID, let rhsSelectableEnsembles) = rhs {
                return lhsWorkerID == rhsWorkerID && lhsSelectableEnsembles == rhsSelectableEnsembles
            }
            return false
        case .workerRequestMessage(let lhsWorkerID, let lhsChunk, let lhsIsFinal):
            if case .workerRequestMessage(let rhsWorkerID, let rhsChunk, let rhsIsFinal) = rhs {
                return lhsWorkerID == rhsWorkerID && lhsChunk == rhsChunk && lhsIsFinal == rhsIsFinal
            }
            return false
        case .workerRequestEOF(let lhsWorkerID):
            if case .workerRequestEOF(let rhsWorkerID) = rhs {
                return lhsWorkerID == rhsWorkerID
            }
            return false
        case .workerError(let lhsWorkerID):
            if case .workerError(let rhsWorkerID) = rhs {
                return lhsWorkerID == rhsWorkerID
            }
            return false
        case .jobHelperEOF:
            if case .jobHelperEOF = rhs {
                return true
            }
            return false
        case .usedLAContext:
            if case .usedLAContext = rhs {
                return true
            }
            return false
        case .requestExecutionError(let lhsRequestExecutionError):
            if case .requestExecutionError(let rhsRequestExecutionError) = rhs {
                return lhsRequestExecutionError == rhsRequestExecutionError
            }
            return false
        }
    }

    public func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        switch self {
        case .responseChunk(let responseChunk):
            buffer.writeInteger(0)
            try responseChunk.encryptedPayload.encode(to: &buffer)
            try responseChunk.isFinal.encode(to: &buffer)
        case .failureReport(let failureReason):
            buffer.writeInteger(1)
            try failureReason.encode(to: &buffer)
        case .findWorker(let findWorkerQuery, let negotiate):
            buffer.writeInteger(2)
            try findWorkerQuery.encode(to: &buffer)
            try negotiate.encode(to: &buffer)
        case .workerDecryptionKey(let uuid, keyID: let keyID, let data):
            buffer.writeInteger(3)
            try uuid.encode(to: &buffer)
            try keyID.encode(to: &buffer)
            try data.encode(to: &buffer)
        case .workerRequestMessage(let uuid, let data, isFinal: let final):
            buffer.writeInteger(4)
            try uuid.encode(to: &buffer)
            try data.encode(to: &buffer)
            try final.encode(to: &buffer)
        case .workerRequestEOF(let uuid):
            buffer.writeInteger(5)
            try uuid.encode(to: &buffer)
        case .workerError(let uuid):
            buffer.writeInteger(6)
            try uuid.encode(to: &buffer)
        case .jobHelperEOF:
            buffer.writeInteger(7)
        case .usedLAContext:
            buffer.writeInteger(8)
        case .requestExecutionError(let requestExecutionError):
            buffer.writeInteger(9)
            try requestExecutionError.encode(to: &buffer)
        case .workerNegotiatePickResponse(let uuid, let selectableEnsembles):
            buffer.writeInteger(10)
            try uuid.encode(to: &buffer)
            try selectableEnsembles.encode(to: &buffer)
        }
    }

    public init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        guard let enumCase: Int = buffer.readInteger() else {
            throw DecodingError.valueNotFound(
                Self.self,
                .init(codingPath: [], debugDescription: "no expected enum case")
            )
        }
        switch enumCase {
        case 0:
            let encryptedPayload = try Data(from: &buffer)
            let isFinal = try Bool(from: &buffer)
            self = .responseChunk(.init(encryptedPayload: encryptedPayload, isFinal: isFinal))
        case 1:
            let failureReason = try FailureReason(from: &buffer)
            self = .failureReport(failureReason)
        case 2:
            self = try .findWorker(
                query: FindWorkerQuery(from: &buffer),
                negotiate: Negotiate(from: &buffer)
            )
        case 3:
            self = try .workerDecryptionKey(
                .init(from: &buffer),
                keyID: .init(from: &buffer),
                .init(from: &buffer)
            )
        case 4:
            self = try .workerRequestMessage(
                .init(from: &buffer),
                .init(from: &buffer),
                isFinal: .init(from: &buffer)
            )
        case 5:
            self = try .workerRequestEOF(.init(from: &buffer))
        case 6:
            self = try .workerError(.init(from: &buffer))
        case 7:
            self = .jobHelperEOF
        case 8:
            self = .usedLAContext
        case 9:
            let requestExecutionError = try RequestExecutionError(from: &buffer)
            self = .requestExecutionError(requestExecutionError)
        case 10:
            self = try .workerNegotiatePickResponse(
                .init(from: &buffer),
                selectableEnsembles: .init(from: &buffer)
            )
        case let value:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(value)"
            ))
        }
    }
}
