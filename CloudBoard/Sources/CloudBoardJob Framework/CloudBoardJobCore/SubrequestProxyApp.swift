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

import Foundation
internal import Synchronization

public struct SubrequestExecution: Sendable {
    public let subrequestID: UInt32
    public let cryptoMaterialHandles: [UUID]
    public let events: SubrequestEventSequence
    public let responseWriter: SubresponseWriter
    public let pccClient: PCCClient
    public let isDiscardable: Bool
}

public struct SubrequestStartEvent: Sendable {}
public struct SubrequestPayload: Sendable {
    public let data: Data
}

public struct SubrequestEndEvent: Sendable {}
public struct SubrequestCancellationEvent: Sendable {}

public enum SubrequestEvent: Sendable, CustomStringConvertible {
    case subrequestStart(SubrequestStartEvent)
    case subrequestPayload(SubrequestPayload)
    case subrequestEnd(SubrequestEndEvent)
    case subrequestCancellation(SubrequestCancellationEvent)

    public var description: String {
        switch self {
        case .subrequestStart: "subrequestStart"
        case .subrequestPayload: "subrequestPayload"
        case .subrequestEnd: "subrequestEnd"
        case .subrequestCancellation: "subrequestCancellation"
        }
    }
}

public final class SubrequestEventSequence: AsyncSequence, Sendable {
    public typealias Element = SubrequestEvent
    let eventStream: AsyncStream<Element>

    init(eventStream: AsyncStream<Element>) {
        self.eventStream = eventStream
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncStream<Element>.AsyncIterator

        public mutating func next() async throws -> Element? {
            await self.iterator.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: self.eventStream.makeAsyncIterator())
    }
}

public final class SubrequestExecutionStream: AsyncSequence, Sendable {
    let subrequestExecutionStream: AsyncStream<SubrequestExecution>
    public typealias Element = SubrequestExecution

    init(requestInputStream: AsyncStream<SubrequestExecution>) {
        self.subrequestExecutionStream = requestInputStream
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncStream<SubrequestExecution>.AsyncIterator

        public mutating func next() async throws -> Element? {
            await self.iterator.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: self.subrequestExecutionStream.makeAsyncIterator())
    }
}

public enum SubresponseStatus: Sendable {
    case ok
    case discarded
    case error(Error)
}

/**
 A writer for streaming response data back to the client for a specific subrequest.

 `SubresponseWriter` manages the response flow for individual subrequests in a proxy application.
 It provides a thread-safe way to write response data and signal completion or errors back to
 the client through the underlying XPC messaging system.

 ## Usage

 The writer operates on an internal async stream that forwards data to the XPC messenger:
 - Call `write(_:)` to send response data chunks
 - Call `finish(status)` to signal completion (with optional error information)

 ## Error Handling

 If an error occurs during response processing, call `finish(status: .error(Error))` with the error.
 If no error occurred, call `finish()` or `finish(status: .ok)` to signal successful completion.
 The underlying XPC messenger will be notified of the completion status and send an EOF marker.

 - Important: Always call `finish(status:)` when done writing. Failing to do so may leave the response stream in an
 incomplete state.
 */
public final class SubresponseWriter: Sendable {
    private let xpcMessenger: JobHelperMessenger
    private let subrequestID: UInt32
    init(messenger: JobHelperMessenger, subrequestID: UInt32) {
        self.xpcMessenger = messenger
        self.subrequestID = subrequestID
    }

    public func write(_ output: Data) async throws {
        try await self.xpcMessenger.sendSubrequestResponse(subrequestID: self.subrequestID, data: output)
    }

    public func finish(status: SubresponseStatus) async throws {
        try await self.xpcMessenger.subresponseEOF(subrequestID: self.subrequestID, status: status)
    }

    public func finish(error: Error? = nil) async throws {
        try await self.finish(status: error.map { .error($0) } ?? .ok)
    }
}

/// When conformed to by a proxy app, CloudBoard will only call `run(SubrequestExecutionStream, ProxyAppEnvironment)`,
/// never `run(InputData, ResponseWriter, CloudAppEnvironment)`. Adopters MUST only implement the former.
@preconcurrency
public protocol SubrequestProxyApp: CloudBoardApp {
    /// This will be called only once per request/connection (and may never be called if the cloud app is never used
    /// for an actual request).
    ///
    /// Returning from this function indicates to CloudBoard that request processing is finished and the process will
    /// exit.
    /// - Parameters:
    ///   - subrequestExecutionStream: A stream of subrequest execution contexts for each received subrequest from the
    ///   client.
    ///   - environment: Provides metadata about the request as well as access to CloudBoard-managed system components.
    func run(
        subrequestExecutionStream: SubrequestExecutionStream,
        environment: ProxyAppEnvironment
    ) async throws
}

extension SubrequestProxyApp {
    public func run(
        input _: InputData,
        responder _: ResponseWriter,
        environment _: CloudAppEnvironment
    ) async throws {
        // This is never expected to be called by CloudBoard, so let's error
        fatalError("Unexpectedly called old-style run on a SubrequestProxyApp")
    }
}

@available(*, unavailable)
extension SubrequestEventSequence.AsyncIterator: Sendable {}

@available(*, unavailable)
extension SubrequestExecutionStream.AsyncIterator: Sendable {}
