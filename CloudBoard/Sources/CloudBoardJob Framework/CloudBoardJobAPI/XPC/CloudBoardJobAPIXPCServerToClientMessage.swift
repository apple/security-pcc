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
internal import CloudBoardLogging
import Foundation

/// Sent from Cloud App to CloudBoardJobHelper.
package struct FindWorkerMessage: Sendable, Equatable, CloudBoardAsyncXPCByteBufferMessage {
    public typealias Success = ExplicitSuccess
    public typealias Failure = Never

    package var query: FindWorkerQuery
    package var subrequestID: UInt32?
    package var cryptoMaterialHandles: [CryptoMaterialHandle]

    internal init(
        query: FindWorkerQuery,
        subrequestID: UInt32?,
        cryptoMaterialHandles: [CryptoMaterialHandle]
    ) {
        self.query = query
        self.subrequestID = subrequestID
        self.cryptoMaterialHandles = cryptoMaterialHandles
    }

    @inlinable
    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.query.encode(to: &buffer)
        try self.subrequestID.encode(to: &buffer)
        try self.cryptoMaterialHandles.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.query = try .init(from: &buffer)
        self.subrequestID = try .init(from: &buffer)
        self.cryptoMaterialHandles = try .init(from: &buffer)
    }
}

package struct WorkerRequestMessage: Sendable, Equatable, CloudBoardAsyncXPCByteBufferMessage {
    public typealias Success = Never
    public typealias Failure = Never

    package var workerID: UUID
    package var message: Data

    internal init(workerID: UUID, message: Data) {
        self.workerID = workerID
        self.message = message
    }

    @inlinable
    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.workerID.encode(to: &buffer)
        try self.message.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.workerID = try UUID(from: &buffer)
        self.message = try Data(from: &buffer)
    }
}

package struct WorkerEOF: Sendable, Equatable, CloudBoardAsyncXPCByteBufferMessage {
    public typealias Success = Never
    public typealias Failure = Never

    package var workerID: UUID
    package var isError: Bool

    internal init(workerID: UUID, isError: Bool) {
        self.workerID = workerID
        self.isError = isError
    }

    @inlinable
    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.workerID.encode(to: &buffer)
        try self.isError.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.workerID = try .init(from: &buffer)
        self.isError = try .init(from: &buffer)
    }
}

package struct FinalizeRequestExecutionLog: CloudBoardAsyncXPCByteBufferMessage, Equatable {
    package typealias Success = Never
    package typealias Failure = Never

    init() {}

    package func encode(to _: inout CloudBoardAsyncXPC.ByteBuffer) throws {}

    package init(from _: inout CloudBoardAsyncXPC.ByteBuffer) throws {}
}

package struct EndOfResponse: CloudBoardAsyncXPCByteBufferMessage, Equatable {
    package typealias Success = ExplicitSuccess
    package typealias Failure = Never

    init() {}

    package func encode(to _: inout CloudBoardAsyncXPC.ByteBuffer) throws {}

    package init(from _: inout CloudBoardAsyncXPC.ByteBuffer) throws {}
}

// We cannot add `extension Data: CloudBoardAsyncXPCByteBufferMessage` directly
// it would leak CloudBoardAsyncXPC into the ABI
// Rather than special case Data everywhere in the (complex) sending path we provide an low
// overhead wrapper thanks to CoW
package struct DataMessage: CloudBoardAsyncXPCByteBufferMessage {
    public typealias Success = Never
    public typealias Failure = Never

    public var data: Data

    package init(_ data: Data) {
        self.data = data
    }

    @inlinable
    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.data.encode(to: &buffer)
    }

    @inlinable
    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.data = try .init(from: &buffer)
    }
}

package struct SubresponsePayload: CloudBoardAsyncXPCByteBufferMessage, Equatable {
    public typealias Success = Never
    public typealias Failure = Never

    public var subresponseID: UInt32
    public var payload: Data

    init(subresponseID: UInt32, payload: Data) {
        self.subresponseID = subresponseID
        self.payload = payload
    }

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.subresponseID.encode(to: &buffer)
        try self.payload.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.subresponseID = try .init(from: &buffer)
        self.payload = try .init(from: &buffer)
    }
}

package struct EndOfSubresponse: CloudBoardAsyncXPCByteBufferMessage, Equatable {
    package typealias Success = ExplicitSuccess
    package typealias Failure = Never
    package var subresponseID: UInt32
    package var status: InternalSubresponseStatus

    init(subresponseID: UInt32, status: InternalSubresponseStatus) {
        self.subresponseID = subresponseID
        self.status = status
    }

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.subresponseID.encode(to: &buffer)
        try self.status.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.subresponseID = try .init(from: &buffer)
        self.status = try .init(from: &buffer)
    }
}

package struct SubresponseInternalError: CloudBoardAsyncXPCByteBufferMessage, Equatable {
    package typealias Success = ExplicitSuccess
    package typealias Failure = Never
    public var subrequestID: UInt32
    package var error: RequestExecutionError?

    init(subrequestID: UInt32, error: RequestExecutionError?) {
        self.subrequestID = subrequestID
        self.error = error
    }

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.subrequestID.encode(to: &buffer)
        try self.error.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.subrequestID = try .init(from: &buffer)
        self.error = try .init(from: &buffer)
    }
}

package enum CloudAppToJobHelperDeriveKeyError: Codable, Sendable, Error {
    /// Any failure to derive or distribute the key
    case failedKeyDerivation
    /// CancellationError. We need a dedicated `Failure` type so can't use that directly.
    case cancelled
}

package enum CloudAppToJobHelperDeriveKeyMessage: CloudBoardAsyncXPCCodableMessage {
    public typealias Success = UUID
    public typealias Failure = CloudAppToJobHelperDeriveKeyError

    case distributeEnsembleKey(info: String, distributionType: CloudBoardJobAPIEnsembleKeyDistributionType)
}

package enum CloudAppToJobHelperDeriveSealedKeyMessage: CloudBoardAsyncXPCCodableMessage {
    public typealias Success = CloudBoardJobAPIEnsembleKeyInfo
    public typealias Failure = CloudAppToJobHelperDeriveKeyError

    case distributeSealedEnsembleKey(info: String, distributionType: CloudBoardJobAPIEnsembleKeyDistributionType)
}

package enum CloudAppToJobHelperPIRError: String, ReportableError, CaseIterable {
    case cancelled
    case failedToDeserializeMessage
    case noEncryptedRequestHandlerSet
    case internalError
}

package struct CloudAppToJobHelperPIRMessage: CloudBoardAsyncXPCByteBufferMessage {
    public typealias Success = CloudBoardJobAPIPIRResponse
    public typealias Failure = CloudAppToJobHelperPIRError

    package let request: CloudBoardJobAPIPIRRequest

    internal init(request: CloudBoardJobAPIPIRRequest) {
        self.request = request
    }

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.request.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.request = try .init(from: &buffer)
    }
}

extension CloudBoardJobAPIPIRRequest: ByteBufferCodable {
    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.payload.encode(to: &buffer)
        try self.purpose.encode(to: &buffer)
        try self.traceContext.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.payload = try .init(from: &buffer)
        self.purpose = try .init(from: &buffer)
        self.traceContext = try .init(from: &buffer)
    }
}

extension CloudBoardJobAPIPIRResponse: ByteBufferCodable {
    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.payload.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.payload = try .init(from: &buffer)
    }
}

extension CloudAppToJobHelperPIRError: ByteBufferCodable {
    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        switch self {
        case .internalError:
            buffer.writeInteger(0)
        case .cancelled:
            buffer.writeInteger(1)
        case .failedToDeserializeMessage:
            buffer.writeInteger(2)
        case .noEncryptedRequestHandlerSet:
            buffer.writeInteger(3)
        }
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        guard let enumCase: Int = buffer.readInteger() else {
            throw DecodingError.valueNotFound(
                Self.self,
                .init(codingPath: [], debugDescription: "no expected enum case")
            )
        }
        switch enumCase {
        case 0:
            self = .internalError
        case 1:
            self = .cancelled
        case 2:
            self = .failedToDeserializeMessage
        case 3:
            self = .noEncryptedRequestHandlerSet
        case let value:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(value)"
            ))
        }
    }
}

package struct CloudAppToJobHelperRequestExecutionError: Sendable, Equatable, CloudBoardAsyncXPCByteBufferMessage {
    public typealias Success = ExplicitSuccess
    public typealias Failure = Never

    package var error: RequestExecutionError

    internal init(error: RequestExecutionError) {
        self.error = error
    }

    @inlinable
    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.error.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.error = try .init(from: &buffer)
    }
}
