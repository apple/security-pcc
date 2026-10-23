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

import Foundation
package import CloudBoardAsyncXPC

package struct AppleSigningServiceTraceContext: Sendable, Hashable, Equatable, ByteBufferCodable {
    package let requestID: String
    package let serverRequestID: String
    package let traceID: UUID
    package let spanID: UInt64

    package init(
        requestID: String,
        serverRequestID: String,
        traceID: UUID,
        spanID: UInt64
    ) {
        self.requestID = requestID
        self.serverRequestID = serverRequestID
        self.traceID = traceID
        self.spanID = spanID
    }

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.requestID.encode(to: &buffer)
        try self.serverRequestID.encode(to: &buffer)
        try self.traceID.encode(to: &buffer)
        try self.spanID.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.requestID = try .init(from: &buffer)
        self.serverRequestID = try .init(from: &buffer)
        self.traceID = try .init(from: &buffer)
        self.spanID = try .init(from: &buffer)
    }
}

public enum AppleSigningServiceError: Equatable, Error {
    case clientUnavailable
    case noRequestHandlerSet
    case internalError
    case failure(AppleSigningServiceProblemDetails)
    case unexpectedError

    // MARK: ByteBufferCodable without declaration

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        switch self {
        case .clientUnavailable:
            buffer.writeHostInteger(0)
        case .noRequestHandlerSet:
            buffer.writeHostInteger(1)
        case .internalError:
            buffer.writeHostInteger(2)
        case .failure(let error):
            buffer.writeHostInteger(3)
            try error.encode(to: &buffer)
        case .unexpectedError:
            buffer.writeHostInteger(4)
        }
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        let rawValue = try buffer.readHostIntegerOrThrow(as: Int.self)
        switch rawValue {
        case 0:
            self = .clientUnavailable
        case 1:
            self = .noRequestHandlerSet
        case 2:
            self = .internalError
        case 3:
            self = try .failure(.init(from: &buffer))
        case 4:
            self = .unexpectedError
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(rawValue)"
            ))
        }
    }
}

/// RFC7807 Problem Details for Apple Signing service HTTP APIs
/// Detail description present in AppleSigningServiceClient openapi.yaml
public struct AppleSigningServiceProblemDetails: Sendable, Equatable {
    /// http response code
    public let code: Int
    /// Human-readable summary of the problem type
    public let title: String
    /// Extended problem explanation
    public let detail: String?
    /// Trace ID and span ID in format traceID-spanID
    public let instance: String?

    package init(
        code: Int,
        title: String,
        detail: String? = nil,
        instance: String? = nil
    ) {
        self.code = code
        self.title = title
        self.detail = detail
        self.instance = instance
    }

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        buffer.writeHostInteger(self.code)
        try self.title.encode(to: &buffer)
        try self.detail.encode(to: &buffer)
        try self.instance.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.code = try buffer.readHostIntegerOrThrow(as: Int.self)
        self.title = try .init(from: &buffer)
        self.detail = try .init(from: &buffer)
        self.instance = try .init(from: &buffer)
    }
}

// This is a wrapper around AppleSigningServiceError, so that the error message can be used across cloudboard boundaries
package struct InternalAppleSigningServiceErrorResponse: Error, Equatable, ByteBufferCodable {
    package let error: AppleSigningServiceError
    package init(error: AppleSigningServiceError) {
        self.error = error
    }

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.error.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.error = try .init(from: &buffer)
    }
}
