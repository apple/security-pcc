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

import CloudBoardUtilities
import Synchronization

struct PCCProtocolHandlerStateMachineEngine: Sendable {
    private enum State: Sendable {
        case awaitingOpen
        case receivingPayloads(PCCCapabilities)
        case receivedFinalMessage(PCCCapabilities)
        case receivedFinalTransportChunk(PCCCapabilities)
        case completedSuccessfully
        case failed(PCCResponseStatus)
        /// The client aborted the request via a `.terminate` message. A subsequent end of the request stream without a
        /// final chunk is a clean abort rather than a protocol violation.
        case aborted
    }

    private var state: State = .awaitingOpen

    /// The number of application payload messages received so far for this request.
    private(set) var applicationPayloadsReceived: Int = 0

    var capabilities: PCCCapabilities? {
        switch state {
        case .receivingPayloads(let c),
            .receivedFinalMessage(let c),
            .receivedFinalTransportChunk(let c):
            return c
        case .awaitingOpen, .completedSuccessfully, .failed, .aborted:
            return nil
        }
    }

    mutating func receiveOpen(capabilities: PCCCapabilities) throws {
        switch state {
        case .awaitingOpen:
            state = .receivingPayloads(capabilities)
        case .receivingPayloads,
            .receivedFinalMessage,
            .receivedFinalTransportChunk,
            .completedSuccessfully:
            throw PrivateCloudComputeProtocolError.receivedDuplicateOpen
        case .failed, .aborted:
            break
        }
    }

    mutating func receiveRequestChunk() throws {
        switch state {
        case .receivedFinalTransportChunk, .completedSuccessfully:
            throw PrivateCloudComputeProtocolError.receivedChunkAfterFinal
        case .awaitingOpen, .receivingPayloads, .receivedFinalMessage, .failed, .aborted:
            break
        }
    }

    /// Records receipt of an application payload message and returns the 1-based index of the
    /// payload within the request.
    mutating func receiveApplicationPayload() throws -> Int {
        switch state {
        case .awaitingOpen:
            throw PrivateCloudComputeProtocolError.receivedApplicationPayloadBeforeOpen
        case .receivedFinalMessage, .receivedFinalTransportChunk, .completedSuccessfully:
            throw PrivateCloudComputeProtocolError.receivedApplicationPayloadAfterFinalMessage
        case .receivingPayloads, .failed, .aborted:
            // .failed / .aborted are unreachable here in practice: parseRequest exits the for-loop before this is
            // reached, so they are defensive no-ops.
            break
        }
        applicationPayloadsReceived += 1
        return applicationPayloadsReceived
    }

    /// Records receipt of the final message. Note that the final message is optional: a request
    /// can instead end with an application payload in the final transport chunk.
    mutating func receiveFinalMessage() throws {
        switch state {
        case .receivingPayloads(let capabilities):
            state = .receivedFinalMessage(capabilities)
        case .awaitingOpen:
            throw PrivateCloudComputeProtocolError.receivedFinalMessageBeforeOpen
        case .receivedFinalMessage,
            .receivedFinalTransportChunk:
            throw PrivateCloudComputeProtocolError.receivedFinalMessageOutOfOrder
        case .completedSuccessfully,
            .failed,
            .aborted:
            break
        }
    }

    mutating func receiveFinalRequestChunk() {
        switch state {
        case .receivingPayloads(let caps), .receivedFinalMessage(let caps):
            state = .receivedFinalTransportChunk(caps)
        case .awaitingOpen,
            .receivedFinalTransportChunk,
            .completedSuccessfully,
            .failed,
            .aborted:
            break
        }
    }

    /// Records that the client aborted the request via a `.terminate`. This makes a subsequent end of the request
    /// stream complete cleanly instead of failing with `streamEndedWithoutFinalChunk`, so the workload handler can
    /// forward a graceful termination signal to the cloud app.
    mutating func receiveTerminate() {
        switch state {
        case .awaitingOpen, .receivingPayloads, .receivedFinalMessage, .receivedFinalTransportChunk:
            state = .aborted
        case .completedSuccessfully, .failed, .aborted:
            break
        }
    }

    mutating func completeSuccessfully() -> PCCResponseStatus {
        switch state {
        case .failed(let status):
            return status
        case .completedSuccessfully:
            // Terminal states are absorbing: completing an already-completed request reports the
            // same success rather than turning it into a failure.
            return .ok
        case .aborted:
            // A client terminate aborts the request cleanly: the stream legitimately ends without
            // a final chunk, so don't treat it as a protocol violation.
            state = .completedSuccessfully
            return .ok
        case .receivedFinalTransportChunk:
            state = .completedSuccessfully
            return .ok
        case .awaitingOpen, .receivingPayloads, .receivedFinalMessage:
            state = .failed(.invalidRequest("streamEndedWithoutFinalChunk"))
            return .invalidRequest("streamEndedWithoutFinalChunk")
        }
    }

    mutating func fail(with status: PCCResponseStatus) {
        state = .failed(status)
    }
}

package final class PCCProtocolHandlerStateMachine: Sendable {
    private let state: Mutex<PCCProtocolHandlerStateMachineEngine>
    private let capabilitiesBox: AsyncValueBox<PCCCapabilities>

    package init() {
        self.state = Mutex(PCCProtocolHandlerStateMachineEngine())
        self.capabilitiesBox = AsyncValueBox()
    }

    package func receiveOpen(capabilities: PCCCapabilities) throws {
        try state.withLock { engine in
            try engine.receiveOpen(capabilities: capabilities)
        }
        capabilitiesBox.put(capabilities)
    }

    package func receiveRequestChunk() throws {
        try state.withLock { engine in
            try engine.receiveRequestChunk()
        }
    }

    package func receiveApplicationPayload() throws -> Int {
        try state.withLock { engine in
            try engine.receiveApplicationPayload()
        }
    }

    /// The number of application payload messages received so far for this request.
    package var applicationPayloadsReceived: Int {
        state.withLock { engine in engine.applicationPayloadsReceived }
    }

    package func receiveFinalMessage() throws {
        try state.withLock { engine in
            try engine.receiveFinalMessage()
        }
    }

    package func receiveFinalRequestChunk() {
        state.withLock { engine in
            engine.receiveFinalRequestChunk()
        }
    }

    /// Marks the request as aborted by a client terminate. See the engine's `receiveTerminate()`.
    package func receiveTerminate() {
        state.withLock { engine in
            engine.receiveTerminate()
        }
    }

    package func completeSuccessfully() throws {
        let status = state.withLock { engine in engine.completeSuccessfully() }
        capabilitiesBox.put(PCCCapabilities(applicationDataChunking: .disabled))
        if case .ok = status { return }
        throw PrivateCloudComputeProtocolError.streamEndedWithoutFinalChunk
    }

    package func fail(with error: any Error) {
        let status = PCCResponseStatus(error)
        state.withLock { engine in
            engine.fail(with: status)
        }
        capabilitiesBox.put(PCCCapabilities(applicationDataChunking: .disabled))
    }

    package func getCapabilities() async throws -> PCCCapabilities {
        try await capabilitiesBox.get()
    }
}
