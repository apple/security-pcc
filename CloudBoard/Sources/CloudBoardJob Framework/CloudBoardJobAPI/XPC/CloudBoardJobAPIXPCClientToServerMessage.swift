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
import Foundation

package enum CloudBoardJobAPIXPCClientToServerMessage {
    case warmup(ManagedWarmupInfo)
    case parameters(ParametersData)
    case invokeWorkload(InvokeWorkloadRequest)
    case teardown

    package enum InvokeWorkloadRequest: ByteBufferCodable, Sendable, Equatable {
        case requestChunk(RequestChunk)
        case receiveWorkerFoundEvent(WorkerFound)
        case receiveWorkerMessage(WorkerResponse)
        case receiveWorkerEOF(WorkerEOF)
        case receiveWorkerResponseSummary(WorkerResponseSummary)
        case openClientSubrequest(OpenClientSubrequest)
        case subrequestPayloadChunk(SubrequestPayloadChunk)
        case closeClientSubrequest(CloseClientSubrequest)
        case cancelClientSubrequest(CancelClientSubrequest)
        case endOfInput
        case configureApplicationDataChunking(ApplicationDataChunkingConfiguration)

        package func encode(to buffer: inout ByteBuffer) throws {
            switch self {
            case .requestChunk(let chunk):
                buffer.writeInteger(0)
                try chunk.encode(to: &buffer)
            case .receiveWorkerResponseSummary(let summary):
                buffer.writeInteger(1)
                try summary.encode(to: &buffer)
            case .receiveWorkerMessage(let message):
                buffer.writeInteger(2)
                try message.encode(to: &buffer)
            case .receiveWorkerFoundEvent(let event):
                buffer.writeInteger(3)
                try event.encode(to: &buffer)
            case .receiveWorkerEOF(let eof):
                buffer.writeInteger(4)
                try eof.encode(to: &buffer)
            case .openClientSubrequest(let subrequest):
                buffer.writeInteger(5)
                try subrequest.encode(to: &buffer)
            case .subrequestPayloadChunk(let subrequest):
                buffer.writeInteger(6)
                try subrequest.encode(to: &buffer)
            case .closeClientSubrequest(let subrequest):
                buffer.writeInteger(7)
                try subrequest.encode(to: &buffer)
            case .cancelClientSubrequest(let subrequest):
                buffer.writeInteger(8)
                try subrequest.encode(to: &buffer)
            case .endOfInput:
                buffer.writeInteger(9)
            case .configureApplicationDataChunking(let config):
                buffer.writeInteger(10)
                try config.encode(to: &buffer)
            }
        }

        package init(from buffer: inout ByteBuffer) throws {
            guard let enumCase: Int = buffer.readInteger() else {
                throw DecodingError.valueNotFound(
                    Self.self,
                    .init(codingPath: [], debugDescription: "no expected enum case")
                )
            }
            switch enumCase {
            case 0:
                self = try .requestChunk(.init(from: &buffer))
            case 1:
                self = try .receiveWorkerResponseSummary(.init(from: &buffer))
            case 2:
                self = try .receiveWorkerMessage(.init(from: &buffer))
            case 3:
                self = try .receiveWorkerFoundEvent(.init(from: &buffer))
            case 4:
                self = try .receiveWorkerEOF(.init(from: &buffer))
            case 5:
                self = try .openClientSubrequest(.init(from: &buffer))
            case 6:
                self = try .subrequestPayloadChunk(.init(from: &buffer))
            case 7:
                self = try .closeClientSubrequest(.init(from: &buffer))
            case 8:
                self = try .cancelClientSubrequest(.init(from: &buffer))
            case 9:
                self = .endOfInput
            case 10:
                self = try .configureApplicationDataChunking(.init(from: &buffer))
            case let value:
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [ByteBufferCodingKey(Self.self)],
                    debugDescription: "bad result enum case \(value)"
                ))
            }
        }
    }

    package typealias InvokeWorkload = InvokeWorkloadRequest
    package typealias Warmup = ManagedWarmupInfo
    package typealias Parameters = ParametersData

    package struct RequestChunk: ByteBufferCodable, Sendable, Equatable {
        package var data: Data

        package init(data: Data) {
            self.data = data
        }

        package func encode(to buffer: inout ByteBuffer) throws {
            try self.data.encode(to: &buffer)
        }

        package init(from buffer: inout ByteBuffer) throws {
            self.data = try .init(from: &buffer)
        }
    }

    package struct OpenClientSubrequest: ByteBufferCodable, Sendable, Equatable {
        package var clientSubrequestID: UInt32
        package var cryptoMaterialHandles: [CryptoMaterialHandle]
        package var isDiscardable: Bool

        package init(
            clientSubrequestID: UInt32,
            cryptoMaterialHandles: [CryptoMaterialHandle],
            isDiscardable: Bool
        ) {
            self.clientSubrequestID = clientSubrequestID
            self.cryptoMaterialHandles = cryptoMaterialHandles
            self.isDiscardable = isDiscardable
        }

        package func encode(to buffer: inout ByteBuffer) throws {
            try self.clientSubrequestID.encode(to: &buffer)
            try self.cryptoMaterialHandles.encode(to: &buffer)
            try self.isDiscardable.encode(to: &buffer)
        }

        package init(from buffer: inout ByteBuffer) throws {
            self.clientSubrequestID = try .init(from: &buffer)
            self.cryptoMaterialHandles = try .init(from: &buffer)
            self.isDiscardable = try .init(from: &buffer)
        }
    }

    package struct SubrequestPayloadChunk: ByteBufferCodable, Sendable, Equatable {
        package var clientSubrequestID: UInt32
        package var chunk: Data

        package init(clientSubrequestID: UInt32, chunk: Data) {
            self.clientSubrequestID = clientSubrequestID
            self.chunk = chunk
        }

        package func encode(to buffer: inout ByteBuffer) throws {
            try self.clientSubrequestID.encode(to: &buffer)
            try self.chunk.encode(to: &buffer)
        }

        package init(from buffer: inout ByteBuffer) throws {
            self.clientSubrequestID = try .init(from: &buffer)
            self.chunk = try .init(from: &buffer)
        }
    }

    package struct CloseClientSubrequest: ByteBufferCodable, Sendable, Equatable {
        package var clientSubrequestID: UInt32

        package init(clientSubrequestID: UInt32) {
            self.clientSubrequestID = clientSubrequestID
        }

        package func encode(to buffer: inout ByteBuffer) throws {
            try self.clientSubrequestID.encode(to: &buffer)
        }

        package init(from buffer: inout ByteBuffer) throws {
            self.clientSubrequestID = try .init(from: &buffer)
        }
    }

    package struct CancelClientSubrequest: ByteBufferCodable, Sendable, Equatable {
        package var clientSubrequestID: UInt32

        package init(clientSubrequestID: UInt32) {
            self.clientSubrequestID = clientSubrequestID
        }

        package func encode(to buffer: inout ByteBuffer) throws {
            try self.clientSubrequestID.encode(to: &buffer)
        }

        package init(from buffer: inout ByteBuffer) throws {
            self.clientSubrequestID = try .init(from: &buffer)
        }
    }

    package struct WorkerFound: ByteBufferCodable, Sendable, Equatable {
        package var workerID: UUID
        package var info: WorkerFoundInfo

        package init(workerID: UUID, info: WorkerFoundInfo) {
            self.workerID = workerID
            self.info = info
        }

        package func encode(to buffer: inout ByteBuffer) throws {
            try self.workerID.encode(to: &buffer)
            try self.info.encode(to: &buffer)
        }

        package init(from buffer: inout ByteBuffer) throws {
            self.workerID = try UUID(from: &buffer)
            self.info = try .init(from: &buffer)
        }
    }

    package struct WorkerResponse: ByteBufferCodable, Sendable, Equatable {
        package var workerID: UUID
        package var message: WorkerResponseMessage

        package init(workerID: UUID, message: WorkerResponseMessage) {
            self.workerID = workerID
            self.message = message
        }

        package func encode(to buffer: inout ByteBuffer) throws {
            try self.workerID.encode(to: &buffer)
            try self.message.encode(to: &buffer)
        }

        package init(from buffer: inout ByteBuffer) throws {
            self.workerID = try UUID(from: &buffer)
            self.message = try .init(from: &buffer)
        }
    }

    package struct WorkerResponseSummary: ByteBufferCodable, Sendable, Equatable {
        package var workerID: UUID
        package var status: WorkerResponseStatus

        package init(workerID: UUID, status: WorkerResponseStatus) {
            self.workerID = workerID
            self.status = status
        }

        package func encode(to buffer: inout ByteBuffer) throws {
            try self.status.encode(to: &buffer)
            try self.workerID.encode(to: &buffer)
        }

        package init(from buffer: inout ByteBuffer) throws {
            self.status = try .init(from: &buffer)
            self.workerID = try UUID(from: &buffer)
        }
    }

    package struct WorkerEOF: ByteBufferCodable, Sendable, Equatable {
        package var workerID: UUID

        package init(workerID: UUID) {
            self.workerID = workerID
        }

        @inlinable
        package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            try self.workerID.encode(to: &buffer)
        }

        package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            self.workerID = try .init(from: &buffer)
        }
    }

    internal struct Teardown: CloudBoardAsyncXPCByteBufferMessage, Equatable {
        internal typealias Success = ExplicitSuccess
        internal typealias Failure = CloudBoardXPCAPIError

        init() {}

        func encode(to _: inout ByteBuffer) throws {}

        init(from _: inout ByteBuffer) throws {}
    }
}

extension CloudBoardJobAPIXPCClientToServerMessage.InvokeWorkload: CloudBoardAsyncXPCByteBufferMessage {
    package typealias Success = ExplicitSuccess
    package typealias Failure = CloudBoardXPCAPIError
}

extension CloudBoardJobAPIXPCClientToServerMessage.Warmup: CloudBoardAsyncXPCByteBufferMessage {
    package typealias Success = ExplicitSuccess
    package typealias Failure = CloudBoardXPCAPIError
}

extension CloudBoardJobAPIXPCClientToServerMessage.Parameters: CloudBoardAsyncXPCByteBufferMessage {
    package typealias Success = ExplicitSuccess
    package typealias Failure = CloudBoardXPCAPIError
}
