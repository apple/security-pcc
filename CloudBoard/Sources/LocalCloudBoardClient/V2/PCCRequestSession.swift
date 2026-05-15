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

// Session protocols and types
import Foundation
internal import InternalSwiftProtobuf
internal import Synchronization

// MARK: - Request Session Protocol

// Namespaced to PCCHarness
extension PCCHarness {
    // MARK: - Compute node request sessions

    /// Session for PCC protocol layer
    public struct PCCProtocolResponseSession: Sendable {
        /// Attestation bundle from the node
        public let attestationBundle: LocalCloudBoardAttestationBundle
        /// PCC protocol response stream
        public let responseStream: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable

        internal let requestContinuation: AsyncStream<Data>.Continuation

        internal init(
            attestationBundle: LocalCloudBoardAttestationBundle,
            requestContinuation: AsyncStream<Data>.Continuation,
            responseStream: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable
        ) {
            self.attestationBundle = attestationBundle
            self.requestContinuation = requestContinuation
            self.responseStream = responseStream
        }

        public func send(_ data: Data) async throws {
            self.requestContinuation.yield(data)
        }

        public func finish() async throws {
            self.requestContinuation.finish()
        }
    }

    /// Internal AsyncSequence that transforms `PrivateCloudComputeProtocolResponse`s to application layer protocol
    /// bytes
    struct ApplicationLayerResponseSequence: AsyncSequence, Sendable {
        typealias Element = Data
        let base: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable

        struct AsyncIterator: AsyncIteratorProtocol {
            var base: any AsyncIteratorProtocol<PCCHarness.PrivateCloudComputeProtocolResponse, any Error>

            mutating func next() async throws -> Data? {
                while let pccResponseMessage = try await self.base.next() {
                    switch pccResponseMessage {
                    case .requestExecutionLogEntry, .responseID, .responseSummary, .payloadChunk,
                         .subresponseOpen, .subresponseClose, .unknown:
                        // Ignore
                        continue
                    case .payload(let payload):
                        return payload
                    }
                }
                return nil
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(base: self.base.makeAsyncIterator())
        }
    }

    /// Unified response stream that merges primary (bypass) and fallback (non-bypass) response streams.
    /// This stream yields from the primary stream first. If the primary stream completes without error,
    /// it will never access the fallback stream. If the primary stream throws an error, that error is
    /// propagated to the consumer.
    struct UnifiedResponseStream<Element: Sendable>: AsyncSequence, Sendable {
        typealias AsyncIterator = Iterator

        private let primaryStream: any AsyncSequence<Element, Error> & Sendable
        private let bypassStream: any AsyncSequence<Element, Error> & Sendable

        init(
            primaryStream: any AsyncSequence<Element, Error> & Sendable,
            bypassStream: any AsyncSequence<Element, Error> & Sendable
        ) {
            self.primaryStream = primaryStream
            self.bypassStream = bypassStream
        }

        func makeAsyncIterator() -> Iterator {
            Iterator(
                primaryIterator: self.primaryStream.makeAsyncIterator(),
                bypassIterator: self.bypassStream.makeAsyncIterator()
            )
        }

        struct Iterator: AsyncIteratorProtocol {
            private var primaryIterator: any AsyncIteratorProtocol<Element, any Error>
            private var bypassIterator: any AsyncIteratorProtocol<Element, any Error>
            private var primaryStreamFinished = false

            init(
                primaryIterator: any AsyncIteratorProtocol<Element, any Error>,
                bypassIterator: any AsyncIteratorProtocol<Element, any Error>
            ) {
                self.primaryIterator = primaryIterator
                self.bypassIterator = bypassIterator
            }

            mutating func next() async throws -> Element? {
                // Note: This relies on the fact, that the proxy response stream is finishing before the bypass stream
                // is used as the proxy hands of the request handling to a compute node.

                // If we're already using the bypass stream, continue with it
                if self.primaryStreamFinished {
                    return try await self.bypassIterator.next()
                }

                // Try to get the next element from the primary stream
                if let element = try await self.primaryIterator.next() {
                    return element
                }
                // Primary stream completed without error, switch to bypass
                self.primaryStreamFinished = true

                return try await self.bypassIterator.next()
            }
        }
    }

    /// Session for application layer
    public struct ApplicationLayerRequestSession: Sendable {
        /// Attestation bundle from the node
        public let attestationBundle: LocalCloudBoardAttestationBundle
        public let responseStream: any AsyncSequence<Data, Error> & Sendable

        internal let requestContinuation: AsyncStream<Data>.Continuation

        internal init(
            attestationBundle: LocalCloudBoardAttestationBundle,
            requestContinuation: AsyncStream<Data>.Continuation,
            responseStream: ApplicationLayerResponseSequence
        ) {
            self.attestationBundle = attestationBundle
            self.requestContinuation = requestContinuation
            self.responseStream = responseStream
        }

        public func send(_ data: Data) async throws {
            self.requestContinuation.yield(data)
        }

        public func finish() async throws {
            self.requestContinuation.finish()
        }
    }

    // MARK: - Proxy node request sessions

    /// Session for proxy application layer - simplified tier 1 API
    public struct ApplicationLayerProxyRequestSession: Sendable {
        /// Attestation bundle from the proxy node
        public let attestationBundle: LocalCloudBoardAttestationBundle
        /// Application-layer response stream (non-bypass)
        package let responseStream: any AsyncSequence<Data, Error> & Sendable
        /// Bypass response stream (package-private for internal testing)
        package let bypassResponseStream: any AsyncSequence<Data, Error> & Sendable

        internal let requestContinuation: AsyncStream<Data>.Continuation

        internal init(
            attestationBundle: LocalCloudBoardAttestationBundle,
            requestContinuation: AsyncStream<Data>.Continuation,
            responseStream: ApplicationLayerResponseSequence,
            bypassResponseStream: ApplicationLayerResponseSequence
        ) {
            self.attestationBundle = attestationBundle
            self.requestContinuation = requestContinuation
            self.responseStream = responseStream
            self.bypassResponseStream = bypassResponseStream
        }

        /// Unified response stream that merges bypass and non-bypass responses
        public var responses: any AsyncSequence<Data, Error> & Sendable {
            UnifiedResponseStream(
                primaryStream: self.responseStream,
                bypassStream: self.bypassResponseStream
            )
        }

        public func send(_ data: Data) async throws {
            self.requestContinuation.yield(data)
        }

        public func finishSending() async throws {
            self.requestContinuation.finish()
        }
    }

    /// Session for PCC protocol layer
    public struct PCCProtocolProxyResponseSession: Sendable {
        /// Attestation bundle from the proxy node
        public let attestationBundle: LocalCloudBoardAttestationBundle
        /// PCC protocol response stream (non-bypass, package-private for internal testing)
        package let responseStream: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable
        /// Response stream for bypass mode (package-private for internal testing)
        package let bypassResponseStream: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable
        /// NACK response streams per proxy endpoint
        public let nackStreams: [
            // swiftformat:disable trailingCommas
            ProxyCloudAppEndpoint: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable
        ]

        internal let requestContinuation: AsyncStream<Data>.Continuation

        internal init(
            attestationBundle: LocalCloudBoardAttestationBundle,
            requestContinuation: AsyncStream<Data>.Continuation,
            responseStream: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable,
            bypassResponseStream: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable,
            nackStreams: [
                // swiftformat:disable trailingCommas
                ProxyCloudAppEndpoint: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable
            ]
        ) {
            self.attestationBundle = attestationBundle
            self.requestContinuation = requestContinuation
            self.responseStream = responseStream
            self.bypassResponseStream = bypassResponseStream
            self.nackStreams = nackStreams
        }

        /// Unified response stream that merges bypass and non-bypass responses
        public var responses: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable {
            UnifiedResponseStream(
                primaryStream: self.responseStream,
                bypassStream: self.bypassResponseStream
            )
        }

        public func send(_ data: Data) async throws {
            self.requestContinuation.yield(data)
        }

        public func finishSending() async throws {
            self.requestContinuation.finish()
        }
    }

    // MARK: - Tier 3: Raw PCC Protocol Sessions (Package-Private for CloudBoard-internal testing)

    /// Session for raw PCC protocol layer on compute nodes
    package struct PCCProtocolRequestSession: Sendable {
        /// Attestation bundle from the node
        package let attestationBundle: LocalCloudBoardAttestationBundle
        /// PCC protocol response stream
        package let responseStream: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable

        internal let requestContinuation: AsyncStream<(PrivateCloudComputeProtocolRequest, Bool)>.Continuation

        internal init(
            attestationBundle: LocalCloudBoardAttestationBundle,
            requestContinuation: AsyncStream<(PrivateCloudComputeProtocolRequest, Bool)>.Continuation,
            responseStream: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable
        ) {
            self.attestationBundle = attestationBundle
            self.requestContinuation = requestContinuation
            self.responseStream = responseStream
        }

        package func send(_ message: PrivateCloudComputeProtocolRequest, isFinal: Bool) async throws {
            self.requestContinuation.yield((message, isFinal))
        }

        package func finish() async throws {
            self.requestContinuation.finish()
        }
    }

    /// Package-private session for raw PCC protocol layer on proxy nodes for internal testing
    package struct PCCProtocolProxyRequestSession: Sendable {
        /// Attestation bundle from the proxy node
        package let attestationBundle: LocalCloudBoardAttestationBundle
        /// PCC protocol response stream
        package let responseStream: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable
        /// Response stream for bypass mode
        package let bypassResponseStream: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable
        /// NACK response streams per proxy endpoint
        package let nackStreams: [
            ProxyCloudAppEndpoint: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable
        ]

        internal let requestContinuation: AsyncStream<(PrivateCloudComputeProtocolRequest, Bool)>.Continuation

        internal init(
            attestationBundle: LocalCloudBoardAttestationBundle,
            requestContinuation: AsyncStream<(PrivateCloudComputeProtocolRequest, Bool)>.Continuation,
            responseStream: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable,
            bypassResponseStream: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable,
            nackStreams: [
                ProxyCloudAppEndpoint: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable
            ]
        ) {
            self.attestationBundle = attestationBundle
            self.requestContinuation = requestContinuation
            self.responseStream = responseStream
            self.bypassResponseStream = bypassResponseStream
            self.nackStreams = nackStreams
        }

        package func send(_ message: PrivateCloudComputeProtocolRequest, isFinal: Bool) async throws {
            self.requestContinuation.yield((message, isFinal))
        }

        package func finishSending() async throws {
            self.requestContinuation.finish()
        }
    }
}

@available(*, unavailable)
extension PCCHarness.ApplicationLayerResponseSequence.AsyncIterator: Sendable {}

@available(*, unavailable)
extension PCCHarness.UnifiedResponseStream.Iterator: Sendable {}
