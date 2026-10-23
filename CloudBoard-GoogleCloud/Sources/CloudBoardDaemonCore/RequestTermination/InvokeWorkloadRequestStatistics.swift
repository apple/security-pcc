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

import CloudBoardProtos
import Synchronization

final class InvokeWorkloadRequestStatistics: Sendable {
    private struct State {
        var rpcID: String?
        var requestChunksReceived: Int = 0
        var finalRequestChunkReceived: Bool = false
        var responseChunksSent: Int = 0
        var finalResponseChunkSent: Bool = false
        var encryptedRequestBytesReceived: Int = 0
        var encryptedResponseBytesSent: Int = 0

        var setupReceivedAt: ContinuousClock.Instant?
        var setupAckSentAt: ContinuousClock.Instant?
        var parametersReceivedAt: ContinuousClock.Instant?
        var parameters: Proto_CloudBoard_InvokeWorkloadRequest.Parameters?
        var firstRequestChunkReceivedAt: ContinuousClock.Instant?
        var finalRequestChunkReceivedAt: ContinuousClock.Instant?
        var firstResponseChunkSentAt: ContinuousClock.Instant?
        var finalResponseChunkSentAt: ContinuousClock.Instant?
        var terminationReceivedAt: ContinuousClock.Instant?
        var terminationCode: Proto_CloudBoard_InvokeWorkloadRequest.Terminate.Code?
        var terminationReason: String?
    }

    private let grpcCallStart: ContinuousClock.Instant
    private let state = Mutex(State())

    init(grpcCallStart: ContinuousClock.Instant) {
        self.grpcCallStart = grpcCallStart
    }

    var rpcID: String? {
        self.state.withLock { $0.rpcID }
    }

    var requestChunksReceived: Int {
        self.state.withLock { $0.requestChunksReceived }
    }

    var finalRequestChunkReceived: Bool {
        self.state.withLock { $0.finalRequestChunkReceived }
    }

    var responseChunksSent: Int {
        self.state.withLock { $0.responseChunksSent }
    }

    var finalResponseChunkSent: Bool {
        self.state.withLock { $0.finalResponseChunkSent }
    }

    var encryptedRequestBytesReceived: Int {
        self.state.withLock { $0.encryptedRequestBytesReceived }
    }

    var encryptedResponseBytesSent: Int {
        self.state.withLock { $0.encryptedResponseBytesSent }
    }

    var parameters: Proto_CloudBoard_InvokeWorkloadRequest.Parameters? {
        self.state.withLock { $0.parameters }
    }

    var terminationCode: Proto_CloudBoard_InvokeWorkloadRequest.Terminate.Code? {
        self.state.withLock { $0.terminationCode }
    }

    var terminationReason: String? {
        self.state.withLock { $0.terminationReason }
    }

    func rpcIdReceived(_ rpcID: String) {
        self.state.withLock { $0.rpcID = rpcID }
    }

    func setupReceived() {
        self.state.withLock { $0.setupReceivedAt = ContinuousClock.now }
    }

    func setupAckSent() {
        self.state.withLock { $0.setupAckSentAt = ContinuousClock.now }
    }

    func parametersReceived(_ parameters: Proto_CloudBoard_InvokeWorkloadRequest.Parameters) {
        self.state.withLock {
            $0.parametersReceivedAt = ContinuousClock.now
            $0.parameters = parameters
        }
    }

    func requestChunkReceived(isFinal: Bool, encryptedByteCount: Int) {
        let now = ContinuousClock.now
        self.state.withLock { state in
            state.requestChunksReceived += 1
            state.encryptedRequestBytesReceived += encryptedByteCount
            if state.firstRequestChunkReceivedAt == nil {
                state.firstRequestChunkReceivedAt = now
            }
            if isFinal {
                state.finalRequestChunkReceived = true
                state.finalRequestChunkReceivedAt = now
            }
        }
    }

    func responseChunkSent(isFinal: Bool, encryptedByteCount: Int) {
        let now = ContinuousClock.now
        self.state.withLock { state in
            state.responseChunksSent += 1
            state.encryptedResponseBytesSent += encryptedByteCount
            if state.firstResponseChunkSentAt == nil {
                state.firstResponseChunkSentAt = now
            }
            if isFinal {
                state.finalResponseChunkSent = true
                state.finalResponseChunkSentAt = now
            }
        }
    }

    func terminationReceived(_ terminate: Proto_CloudBoard_InvokeWorkloadRequest.Terminate) {
        self.state.withLock {
            $0.terminationReceivedAt = ContinuousClock.now
            $0.terminationCode = terminate.code
            $0.terminationReason = terminate.hasReason ? terminate.reason : nil
        }
    }
}

extension InvokeWorkloadRequestStatistics {
    /// Whether the setupAck has been sent to the client yet. Used to detect requests that were
    /// cancelled before we acknowledged setup (e.g. a ROPES setup-phase timeout).
    var hasSentSetupAck: Bool {
        self.state.withLock { $0.setupAckSentAt != nil }
    }
}

extension InvokeWorkloadRequestStatistics {
    struct Durations {
        var total: Duration?
        var grpcCallStartToSetup: Duration?
        var setupToSetupAck: Duration?
        var setupAckToParameters: Duration?
        var setupToParameters: Duration?
        var setupToFirstRequestChunk: Duration?
        var parametersToFirstRequestChunk: Duration?
        var firstRequestChunkToFirstResponseChunk: Duration?
        var firstRequestChunkToFinalRequestChunk: Duration?
        var firstRequestChunkToFinalResponseChunk: Duration?
        var finalRequestChunkToFirstResponseChunk: Duration?
        var finalRequestChunkToFinalResponseChunk: Duration?
        var firstResponseChunkToFinalResponseChunk: Duration?
        var finalResponseChunkToCallEnd: Duration?
        var terminationReceivedToCallEnd: Duration?
    }

    func durations() -> Durations {
        let callEnd = ContinuousClock.now
        let snapshot = self.state.withLock { state in
            (
                setupReceivedAt: state.setupReceivedAt,
                setupAckSentAt: state.setupAckSentAt,
                parametersReceivedAt: state.parametersReceivedAt,
                firstRequestChunkAt: state.firstRequestChunkReceivedAt,
                finalRequestChunkAt: state.finalRequestChunkReceivedAt,
                firstResponseChunkAt: state.firstResponseChunkSentAt,
                finalResponseChunkAt: state.finalResponseChunkSentAt,
                terminationReceivedAt: state.terminationReceivedAt
            )
        }

        return Durations(
            total: callEnd - self.grpcCallStart,
            grpcCallStartToSetup: duration(from: self.grpcCallStart, to: snapshot.setupReceivedAt),
            setupToSetupAck: duration(from: snapshot.setupReceivedAt, to: snapshot.setupAckSentAt),
            setupAckToParameters: duration(from: snapshot.setupAckSentAt, to: snapshot.parametersReceivedAt),
            setupToParameters: duration(from: snapshot.setupReceivedAt, to: snapshot.parametersReceivedAt),
            setupToFirstRequestChunk: duration(from: snapshot.setupReceivedAt, to: snapshot.firstRequestChunkAt),
            parametersToFirstRequestChunk: duration(
                from: snapshot.parametersReceivedAt,
                to: snapshot.firstRequestChunkAt
            ),
            firstRequestChunkToFirstResponseChunk: duration(
                from: snapshot.firstRequestChunkAt,
                to: snapshot.firstResponseChunkAt
            ),
            firstRequestChunkToFinalRequestChunk: duration(
                from: snapshot.firstRequestChunkAt,
                to: snapshot.finalRequestChunkAt
            ),
            firstRequestChunkToFinalResponseChunk: duration(
                from: snapshot.firstRequestChunkAt,
                to: snapshot.finalResponseChunkAt
            ),
            finalRequestChunkToFirstResponseChunk: duration(
                from: snapshot.finalRequestChunkAt,
                to: snapshot.firstResponseChunkAt
            ),
            finalRequestChunkToFinalResponseChunk: duration(
                from: snapshot.finalRequestChunkAt,
                to: snapshot.finalResponseChunkAt
            ),
            firstResponseChunkToFinalResponseChunk: duration(
                from: snapshot.firstResponseChunkAt,
                to: snapshot.finalResponseChunkAt
            ),
            finalResponseChunkToCallEnd: duration(from: snapshot.finalResponseChunkAt, to: callEnd),
            terminationReceivedToCallEnd: duration(from: snapshot.terminationReceivedAt, to: callEnd)
        )
    }
}

private func duration(from: ContinuousClock.Instant?, to: ContinuousClock.Instant?) -> Duration? {
    guard let from, let to else { return nil }
    // Clamp to zero because events can occur out of logical order (e.g. response streaming
    // starts before all request chunks arrive), and negative durations crash swift-otel's
    // histogram bucket representation which requires unsigned values.
    return max(to - from, .zero)
}
