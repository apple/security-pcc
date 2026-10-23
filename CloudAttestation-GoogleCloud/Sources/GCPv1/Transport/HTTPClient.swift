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
import Logging
import NIOCore
import NIOEmbedded
import NIOHTTP1
import SwiftProtobuf

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct HTTPClient: Sendable {
    private static let logger = Logger(label: "com.apple.CloudAttestation.GCPv1.HTTPClient")

    private let socketPath: String
    private let debug: Bool
    private static let codableDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(socketPath: String, debug: Bool = false) {
        self.socketPath = socketPath
        self.debug = debug
    }

    func get<Response: SwiftProtobuf.Message & Sendable>(path: String) throws(GCPv1Error) -> Response {
        let (statusCode, body) = try sendRequest(method: .GET, path: path, body: nil)
        let validated = try validateResponse(statusCode: statusCode, body: body)
        do {
            return try Response(jsonUTF8Data: validated)
        } catch {
            throw .decodingError(error)
        }
    }

    func post<Request: SwiftProtobuf.Message & Sendable, Response: SwiftProtobuf.Message & Sendable>(
        path: String,
        body request: Request
    ) throws(GCPv1Error) -> Response {
        let (statusCode, body) = try sendRequest(method: .POST, path: path, body: encode(request))
        let validated = try validateResponse(statusCode: statusCode, body: body)
        do {
            return try Response(jsonUTF8Data: validated)
        } catch {
            throw .decodingError(error)
        }
    }

    func post<Request: SwiftProtobuf.Message & Sendable>(
        path: String,
        body request: Request
    ) throws(GCPv1Error) {
        let (statusCode, body) = try sendRequest(method: .POST, path: path, body: encode(request))
        try validateResponse(statusCode: statusCode, body: body)
    }

    // For endpoints that return non-proto Codable responses (e.g., KeyEndorsement).

    func postForCodableResponse<Request: SwiftProtobuf.Message & Sendable, Response: Decodable & Sendable>(
        path: String,
        body request: Request
    ) throws(GCPv1Error) -> Response {
        let (statusCode, body) = try sendRequest(method: .POST, path: path, body: encode(request))
        let validated = try validateResponse(statusCode: statusCode, body: body)
        do {
            return try Self.codableDecoder.decode(Response.self, from: validated)
        } catch {
            throw .decodingError(error)
        }
    }

    // MARK: - Private

    private func encode<Request: SwiftProtobuf.Message>(_ request: Request) throws(GCPv1Error) -> Data {
        do {
            return try request.jsonUTF8Data()
        } catch {
            throw .encodingError(error)
        }
    }

    @discardableResult
    private func validateResponse(statusCode: Int, body: Data) throws(GCPv1Error) -> Data {
        if debug {
            FileHandle.standardError.write(Data("[DEBUG] HTTP \(statusCode)\n".utf8))
            let bodyString = String(data: body, encoding: .utf8) ?? "<non-utf8, \(body.count) bytes>"
            FileHandle.standardError.write(Data("[DEBUG] Body: \(bodyString)\n".utf8))
        }
        guard (200..<300).contains(statusCode) else {
            Self.logger.warning(
                "Non-2xx HTTP response from GCPv1 socket",
                metadata: [
                    "statusCode": .stringConvertible(statusCode),
                    "bodyBytes": .stringConvertible(body.count),
                ]
            )
            throw .requestFailed(statusCode: statusCode, body: String(data: body, encoding: .utf8))
        }
        return body
    }

    private func sendRequest(method: HTTPMethod, path: String, body: Data?) throws(GCPv1Error) -> (Int, Data) {
        let fd = try connectToSocket()
        defer { close(fd) }

        // Set up a shared EmbeddedChannel with both encoder and decoder so the
        // response decoder's state machine sees the outgoing request.
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish(acceptAlreadyClosed: true) }

        do {
            try channel.pipeline.syncOperations.addHandler(HTTPRequestEncoder())
            try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(HTTPResponseDecoder()))

            // Encode the request
            var headers = HTTPHeaders()
            headers.add(name: "Host", value: "localhost")
            headers.add(name: "Connection", value: "close")
            if let body {
                headers.add(name: "Content-Type", value: "application/json")
                headers.add(name: "Content-Length", value: "\(body.count)")
            }

            let head = HTTPRequestHead(version: .http1_1, method: method, uri: path, headers: headers)
            try channel.writeOutbound(HTTPClientRequestPart.head(head))

            if let body {
                var buffer = channel.allocator.buffer(capacity: body.count)
                buffer.writeBytes(body)
                try channel.writeOutbound(HTTPClientRequestPart.body(.byteBuffer(buffer)))
            }

            try channel.writeOutbound(HTTPClientRequestPart.end(nil))

            // Read encoded request bytes and write to socket
            var requestData = Data()
            while var buffer = try channel.readOutbound(as: ByteBuffer.self) {
                requestData.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
            }
            try writeAll(fd: fd, data: requestData)

            // Read raw response from socket
            var rawResponse = Data()
            let bufferSize = 4096
            var readBuffer = [UInt8](repeating: 0, count: bufferSize)
            while true {
                let bytesRead = read(fd, &readBuffer, bufferSize)
                if bytesRead < 0 {
                    throw GCPv1Error.socketError("Failed to read response: \(String(cString: strerror(errno)))")
                }
                if bytesRead == 0 { break }
                rawResponse.append(readBuffer, count: bytesRead)
            }

            // Decode response through the same channel
            var nioBuffer = channel.allocator.buffer(capacity: rawResponse.count)
            nioBuffer.writeBytes(rawResponse)
            try channel.writeInbound(nioBuffer)

            var statusCode = 0
            var responseBody = Data()

            while let part: HTTPClientResponsePart = try channel.readInbound() {
                switch part {
                case .head(let head):
                    statusCode = Int(head.status.code)
                case .body(var buf):
                    if let bytes = buf.readBytes(length: buf.readableBytes) {
                        responseBody.append(contentsOf: bytes)
                    }
                case .end:
                    break
                }
            }

            return (statusCode, responseBody)
        } catch let error as GCPv1Error {
            throw error
        } catch {
            Self.logger.error(
                "Request transport failed; rethrowing as invalidResponse",
                metadata: [
                    "method": .string(String(describing: method)),
                    "path": .string(path),
                    "error": .string(String(describing: error)),
                ]
            )
            throw .invalidResponse
        }
    }

    private func connectToSocket() throws(GCPv1Error) -> Int32 {
        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else {
            throw .socketError("Failed to create socket: \(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw .socketError("Socket path too long: \(socketPath)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { ptr in
                for (i, byte) in pathBytes.enumerated() {
                    ptr[i] = byte
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            close(fd)
            throw .connectionFailed(socketPath: socketPath, underlying: POSIXError(errno))
        }

        return fd
    }

    private func writeAll(fd: Int32, data: Data) throws(GCPv1Error) {
        var totalWritten = 0
        while totalWritten < data.count {
            let written = data.withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress! + totalWritten, buffer.count - totalWritten)
            }
            guard written >= 0 else {
                throw .socketError("Failed to write request: \(String(cString: strerror(errno)))")
            }
            totalWritten += written
        }
    }
}

private struct POSIXError: Swift.Error, CustomStringConvertible {
    let code: Int32

    init(_ code: Int32) {
        self.code = code
    }

    var description: String {
        String(cString: strerror(code))
    }
}
