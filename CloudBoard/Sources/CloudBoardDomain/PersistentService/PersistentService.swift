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

import CryptoKit
import Foundation
package import CloudBoardAsyncXPC

/// Namespace for domain types specific to the PersistentService functionality.
public enum PersistentService: Sendable {
    /// Maximum number of filter queries a single persistent helper instance will process
    /// before gracefully self-terminating.
    package static let maxFilterQueryCount: UInt64 = 1 << 32

    /// Compute the last 64 bits of SHA-256 of a name string, as a big-endian UInt64.
    ///
    /// Used to derive deterministic numeric identifiers from human-readable service
    /// and filter names. The result is portable across architectures.
    public static func sha256Last8(_ name: String) -> UInt64 {
        let digest = SHA256.hash(data: Data(name.utf8))
        var value: UInt64 = 0
        for byte in digest.suffix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    /// Zero-padded 16-character lowercase hex representation of ``sha256Last8(_:)``.
    ///
    /// This is the canonical string form used in ``FilterShardMetadata/ShardInfo/filterIDHash``
    /// and ``FilterShardMetadata/ShardInfo/hashingIDHash``. Using this method avoids
    /// duplicating the padding logic across producers and consumers.
    public static func paddedHexHash(_ name: String) -> String {
        let value = self.sha256Last8(name)
        return self.paddedHex(value)
    }

    /// Zero-padded 16-character lowercase hex representation of a UInt64 hash value.
    public static func paddedHex(_ value: UInt64) -> String {
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}

extension PersistentService {
    /// Known persistent service names, keyed by their SHA256-last-8 service ID.
    ///
    /// Add entries here when registering new persistent services so that metric
    /// labels and log messages can use human-readable names.
    package static let knownServiceNames: [UInt64: String] = [
        sha256Last8("trusted-filter"): "trusted-filter",
    ]

    /// Returns the human-readable service name for a service ID, or a hex fallback.
    package static func serviceName(for serviceID: UInt64) -> String {
        self.knownServiceNames[serviceID] ?? "unknown(\(self.paddedHex(serviceID)))"
    }
}

extension PersistentService {
    /// Last 64 bits of SHA-256 of the service ID string.
    public struct Identity: Hashable, Sendable {
        public let serviceID: UInt64

        public init(serviceID: UInt64) {
            self.serviceID = serviceID
        }

        // MARK: ByteBufferCodable without declaration

        package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            try self.serviceID.encode(to: &buffer)
        }

        package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            self.serviceID = try .init(from: &buffer)
        }

        /// Computes the service ID from a service name string.
        /// The service ID is the last 64 bits of the SHA-256 hash of the UTF-8 encoded name.
        public static func serviceID(for name: String) -> UInt64 {
            PersistentService.sha256Last8(name)
        }
    }

    /// Error information returned from a persistent service query.
    public struct ErrorInfo: Sendable, Hashable, Equatable {
        public let code: Int
        public let message: String

        public init(code: Int, message: String) {
            self.code = code
            self.message = message
        }

        // MARK: ByteBufferCodable without declaration

        package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            buffer.writeHostInteger(self.code)
            try self.message.encode(to: &buffer)
        }

        package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            self.code = try buffer.readHostIntegerOrThrow(as: Int.self)
            self.message = try .init(from: &buffer)
        }
    }

    /// Opaque correlation identifier for matching queries to responses.
    /// Currently backed by UUID but wrapped for future flexibility.
    public struct QueryCorrelationID: Hashable, Sendable, Equatable, CustomStringConvertible {
        public var description: String {
            return self.rawValue.uuidString
        }

        public let rawValue: UUID

        /// Make a new correlation ID automatically
        public init() {
            self.rawValue = UUID()
        }

        public init(rawValue: UUID) {
            self.rawValue = rawValue
        }

        // MARK: ByteBufferCodable without declaration

        package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            try self.rawValue.encode(to: &buffer)
        }

        package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            self.rawValue = try .init(from: &buffer)
        }
    }

    /// Payload of a persistent service response, either a success with opaque data or an error.
    public enum ResponsePayload: Sendable, Equatable {
        case success(Data)
        case error(ErrorInfo)

        // MARK: ByteBufferCodable without declaration

        package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            switch self {
            case .success(let data):
                buffer.writeHostInteger(0)
                try data.encode(to: &buffer)
            case .error(let errorInfo):
                buffer.writeHostInteger(1)
                try errorInfo.encode(to: &buffer)
            }
        }

        package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            let rawValue = try buffer.readHostIntegerOrThrow(as: Int.self)
            switch rawValue {
            case 0:
                self = try .success(.init(from: &buffer))
            case 1:
                self = try .error(.init(from: &buffer))
            default:
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [ByteBufferCodingKey(Self.self)],
                    debugDescription: "bad result enum case \(rawValue)"
                ))
            }
        }
    }

    /// Response correlated to a query by its correlation ID.
    public struct Response: Sendable, Equatable {
        public let correlationID: QueryCorrelationID
        public let payload: ResponsePayload
        /// The time the original query was sent, carried here so clients don't
        /// need to track it separately for latency metrics.
        public let querySentAt: Date

        public init(correlationID: QueryCorrelationID, payload: ResponsePayload, querySentAt: Date) {
            self.correlationID = correlationID
            self.payload = payload
            self.querySentAt = querySentAt
        }

        // MARK: ByteBufferCodable without declaration

        package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            try self.correlationID.encode(to: &buffer)
            try self.payload.encode(to: &buffer)
            try self.querySentAt.encode(to: &buffer)
        }

        package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            self.correlationID = try .init(from: &buffer)
            self.payload = try .init(from: &buffer)
            self.querySentAt = try .init(from: &buffer)
        }
    }
}
