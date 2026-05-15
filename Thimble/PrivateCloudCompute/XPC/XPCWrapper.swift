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

//
//  XPCWrapper.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Dispatch
import Foundation_Private.NSXPCConnection
import XPC
import XPCPrivate
import os

package struct XPCSubrequest: Sendable, Equatable, Codable, TC2JSON {
    /// Represents encoded `XPCSubrequest`.  Use `XPCSubrequest(json:)` to convert.
    package typealias Data = Foundation.Data

    package enum Priority: Sendable, Equatable, Codable, TC2JSON {
        case unspecified
        case discardable
    }
    package var requestId: UInt64
    package var priority: Priority

    package init(requestId: UInt64, request: PrivateCloudComputeConnection.Request) {
        self.requestId = requestId
        switch request.priority {
        case .unspecified:
            self.priority = .unspecified
        case .discardable:
            self.priority = .discardable
        }
    }
}

package protocol XPCWrapperProtocol: Sendable {
    associatedtype RequestProxy: TC2XPCTrustedRequestProtocol

    func cancel(connectionID: Int, proxy: RequestProxy) async
    func close(connectionID: Int, proxy: RequestProxy) async
    func send(connectionID: Int, proxy: RequestProxy, message: XPCRequestMessage) async throws
    func next(connectionID: Int, proxy: RequestProxy) async throws -> XPCResponseMessage?
    func nextProgress(connectionID: Int, proxy: RequestProxy) async throws -> PrivateCloudComputeConnection.Progress?

    func createSubrequest(
        connectionID: Int,
        proxy: RequestProxy,
        subrequest: XPCSubrequest
    ) async throws

    func trustedRequest(
        withParameters parameters: Data,
        requestID: UUID,
        multiTurn: Bool,
        bundleIdentifier: String?,
        originatingBundleIdentifier: String?,
        featureIdentifier: String?,
        sessionIdentifier: UUID?
    ) async throws -> any XPCRequestProxyProtocol

    func connection(
        withParameters parameters: Data,
        connectionIdentifier: UUID,
        bundleIdentifier: String?,
        originatingBundleIdentifier: String?,
        featureIdentifier: String?,
        sessionIdentifier: UUID?
    ) async throws -> any XPCRequestProxyProtocol

    func close()
    func currentEnvironment() async throws -> String
    func prefetchRequest(
        _ request: Prefetch
    ) async throws -> [Prefetch.Response]
    func prewarmRequest(
        workloadType: String,
        workloadParameters: [String: String],
        bundleIdentifier: String?,
        featureIdentifier: String,
        runOnEventStream: Bool
    ) async throws
    func prefetchParametersCache() async throws -> [String]
    func prefetchParametersCacheSavedState() async throws -> [String]
    func prefetchCacheReset() async throws -> Bool
    func prefetchCache() async throws -> [String]
    func knownRateLimits(
        bundleIdentifier: String?,
        featureIdentifier: String?,
        skipFetch: Bool
    ) async throws -> Data?
    func listRateLimits(
        bundleIdentifier: String?,
        featureIdentifier: String?,
        fetch: Bool
    ) async throws -> Data?
    func addRateLimit(
        bundleIdentifier: String?,
        featureIdentifier: String?,
        workloadType: String?,
        count: UInt,
        duration: Double,
        ttl: Double,
        jitter: Double
    ) async throws
    func resetRateLimits() async throws
    func fetchServerDrivenConfiguration() async throws -> Data
    func listServerDrivenConfiguration() async throws -> Data
    func setServerDrivenConfiguration(json: Data) async throws -> Data
}

/// This class wraps the NSXPCConnection and ensures that Swift concurrency
/// task cancellation is forwarded properly. Also it ensures that all dangling requests
/// are failed in case the daemon crashes.
package final actor XPCWrapper: XPCWrapperProtocol {
    nonisolated package var unownedExecutor: UnownedSerialExecutor {
        self.queue.asUnownedSerialExecutor()
    }

    private enum Continuation {
        case void(CheckedContinuation<Void, any Error>)
        case bool(CheckedContinuation<Bool, any Error>)
        case data(CheckedContinuation<Data, any Error>)
        case optionalData(CheckedContinuation<Data?, any Error>)
        case string(CheckedContinuation<String, any Error>)
        case stringArray(CheckedContinuation<[String], any Error>)
        case requestProxy(CheckedContinuation<(any TC2XPCTrustedRequestProtocol, Int), any Error>)
        case optionalResponseMessage(CheckedContinuation<XPCResponseMessage?, any Error>)
        case optionalProgress(CheckedContinuation<PrivateCloudComputeConnection.Progress?, any Error>)

        func resume(throwing error: any Error) {
            switch self {
            case .void(let checkedContinuation):
                checkedContinuation.resume(throwing: error)
            case .bool(let checkedContinuation):
                checkedContinuation.resume(throwing: error)
            case .data(let checkedContinuation):
                checkedContinuation.resume(throwing: error)
            case .optionalData(let checkedContinuation):
                checkedContinuation.resume(throwing: error)
            case .string(let checkedContinuation):
                checkedContinuation.resume(throwing: error)
            case .stringArray(let checkedContinuation):
                checkedContinuation.resume(throwing: error)
            case .requestProxy(let checkedContinuation):
                checkedContinuation.resume(throwing: error)
            case .optionalResponseMessage(let checkedContinuation):
                checkedContinuation.resume(throwing: error)
            case .optionalProgress(let checkedContinuation):
                checkedContinuation.resume(throwing: error)
            }
        }
    }

    private var _nextRequestID: Int = 0
    private var _nextConnectionID: Int = 1

    private let queue: DispatchSerialQueue
    private let jsonDecoder = JSONDecoder()
    private let userID: uid_t?
    private var connectionID: Int = 0
    private var connection: NSXPCConnection
    private var xpc: any TC2DaemonProtocol

    private var runningRequests: [Int: Continuation] = [:]

    package init(userID: uid_t? = nil) {
        self.userID = userID
        self.queue = DispatchSerialQueue(label: "com.apple.privatecloudcompute.xpc.connection")

        let connection = NSXPCConnection(machServiceName: "com.apple.privatecloudcompute")
        connection._setQueue(self.queue)
        connection.remoteObjectInterface = interfaceForTC2DaemonProtocol()
        #if os(macOS)
        if let userID {
            connection._setTargetUserIdentifier(userID)
        }
        #endif
        self.connection = connection

        // We want to crash here! If the `remoteObjectProxy` does not conform to `TC2DaemonProtocol`
        // the framework and deamon have gotten out of sync. This is an irrecoverable error anyway.
        self.xpc = self.connection.remoteObjectProxy as! (any TC2DaemonProtocol)

        connection.interruptionHandler = {
            self.assumeIsolated { wrapper in
                wrapper.failAllRunningRequestsAndRestartConnection()
            }
        }

        // start the connection
        connection.resume()
    }

    nonisolated package func close() {
        self.queue.async {
            self.assumeIsolated { wrapper in
                precondition(wrapper.runningRequests.isEmpty)
                wrapper.connection.invalidate()
                wrapper.connection.interruptionHandler = nil
            }
        }
    }

    // MARK: - XPC Methods

    package func trustedRequest(
        withParameters parameters: Data,
        requestID: UUID,
        multiTurn: Bool,
        bundleIdentifier: String?,
        originatingBundleIdentifier: String?,
        featureIdentifier: String?,
        sessionIdentifier: UUID?
    ) async throws -> any XPCRequestProxyProtocol {
        let xpcRequestID = self.nextRequestID()
        let (proxy, connectionID) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(any TC2XPCTrustedRequestProtocol, Int), any Error>) in
            self.storeContinuation(continuation, id: xpcRequestID)

            self.xpc.trustedRequest(
                withParameters: parameters,
                requestID: requestID,
                multiTurn: multiTurn,
                bundleIdentifier: bundleIdentifier,
                originatingBundleIdentifier: originatingBundleIdentifier,
                featureIdentifier: featureIdentifier,
                sessionIdentifier: sessionIdentifier
            ) { proxy, errorData in
                self.assumeIsolated { wrapper in
                    if let errorData {
                        if let error = PrivateCloudComputeError(json: errorData) {
                            wrapper.failContinuation(id: xpcRequestID, error: error)
                        } else {
                            let error = PrivateCloudComputeError(message: "failed to get request proxy and decode error")
                            wrapper.failContinuation(id: xpcRequestID, error: error)
                        }
                    } else if let proxy {
                        // we must capture the connection ID, in the moment where we receive the
                        // proxy object
                        wrapper.finishContinuation(id: xpcRequestID, with: proxy, connectionID: wrapper.connectionID)
                    } else {
                        let error = PrivateCloudComputeError(message: "failed to get request proxy")
                        wrapper.failContinuation(id: xpcRequestID, error: error)
                    }
                }
            }
        }
        return XPCRequestProxy(connectionID: connectionID, proxy: proxy, wrapper: self)
    }

    /// Uses `connectionIdentifier` as client's `requestID` when creating `XPCRequestProxy`.
    package func connection(
        withParameters parameters: Data,
        connectionIdentifier: UUID,
        bundleIdentifier: String?,
        originatingBundleIdentifier: String?,
        featureIdentifier: String?,
        sessionIdentifier: UUID?
    ) async throws -> any XPCRequestProxyProtocol {
        try await trustedRequest(
            withParameters: parameters,
            requestID: connectionIdentifier,
            multiTurn: true,
            bundleIdentifier: bundleIdentifier,
            originatingBundleIdentifier: originatingBundleIdentifier,
            featureIdentifier: featureIdentifier,
            sessionIdentifier: sessionIdentifier
        )
    }

    package func currentEnvironment() async throws -> String {
        let requestID = self.nextRequestID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            self.storeContinuation(continuation, id: requestID)

            self.xpc.currentEnvironment { result in
                self.assumeIsolated { wrapper in
                    wrapper.finishContinuation(id: requestID, with: result)
                }
            }
        }
    }

    /// Tests connection to daemon. Should return the same string passed in.
    func echo(text: String) async throws -> String {
        let requestID = self.nextRequestID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            self.storeContinuation(continuation, id: requestID)

            self.xpc.echo(text: text) { result in
                self.assumeIsolated { wrapper in
                    wrapper.finishContinuation(id: requestID, with: result)
                }
            }
        }
    }

    package func prefetchRequest(
        _ request: Prefetch
    ) async throws -> [Prefetch.Response] {
        let requestID = self.nextRequestID()
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
            self.storeContinuation(continuation, id: requestID)

            self.xpc.prefetchRequest(workloadType: request.workloadType, workloadParameters: request.workloadParameters ?? [:]) { data in
                self.assumeIsolated { wrapper in
                    wrapper.finishContinuation(id: requestID, with: data)
                }
            }
        }

        guard let data else { return [] }

        return try self.jsonDecoder.decode([Prefetch.Response].self, from: data)
    }

    package func prewarmRequest(
        workloadType: String,
        workloadParameters: [String: String],
        bundleIdentifier: String?,
        featureIdentifier: String,
        runOnEventStream: Bool
    ) async throws {
        let requestID = self.nextRequestID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.storeContinuation(continuation, id: requestID)

            self.xpc.prewarmRequest(
                workloadType: workloadType,
                workloadParameters: workloadParameters,
                bundleIdentifier: bundleIdentifier,
                featureIdentifier: featureIdentifier,
                runOnEventStream: runOnEventStream
            ) {
                self.assumeIsolated { wrapper in
                    wrapper.finishContinuation(id: requestID)
                }
            }
        }
    }

    package func prefetchCache() async throws -> [String] {
        let requestID = self.nextRequestID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], any Error>) in
            self.storeContinuation(continuation, id: requestID)

            self.xpc.prefetchCache { result in
                self.assumeIsolated { wrapper in
                    wrapper.finishContinuation(id: requestID, with: result)
                }
            }
        }
    }

    package func prefetchParametersCache() async throws -> [String] {
        let requestID = self.nextRequestID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], any Error>) in
            self.storeContinuation(continuation, id: requestID)

            self.xpc.prefetchParametersCache { result in
                self.assumeIsolated { wrapper in
                    wrapper.finishContinuation(id: requestID, with: result)
                }
            }
        }
    }

    package func prefetchParametersCacheSavedState() async throws -> [String] {
        let requestID = self.nextRequestID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], any Error>) in
            self.storeContinuation(continuation, id: requestID)

            self.xpc.prefetchParametersCacheSavedState { result in
                self.assumeIsolated { wrapper in
                    wrapper.finishContinuation(id: requestID, with: result)
                }
            }
        }
    }

    package func prefetchCacheReset() async throws -> Bool {
        let requestID = self.nextRequestID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            self.storeContinuation(continuation, id: requestID)

            self.xpc.prefetchCacheReset { result in
                self.assumeIsolated { wrapper in
                    wrapper.finishContinuation(id: requestID, with: result)
                }
            }
        }
    }

    package func knownRateLimits(
        bundleIdentifier: String?,
        featureIdentifier: String?,
        skipFetch: Bool
    ) async throws -> Data? {
        let requestID = self.nextRequestID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
            self.storeContinuation(continuation, id: requestID)

            self.xpc.knownRateLimits(
                bundleIdentifier: bundleIdentifier,
                featureIdentifier: featureIdentifier,
                skipFetch: skipFetch
            ) { data in
                self.assumeIsolated { wrapper in
                    wrapper.finishContinuation(id: requestID, with: data)
                }
            }
        }
    }

    package func listRateLimits(
        bundleIdentifier: String?,
        featureIdentifier: String?,
        fetch: Bool
    ) async throws -> Data? {
        let requestID = self.nextRequestID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
            self.storeContinuation(continuation, id: requestID)

            self.xpc.listRateLimits(
                bundleIdentifier: bundleIdentifier,
                featureIdentifier: featureIdentifier,
                fetch: fetch
            ) { data in
                self.assumeIsolated { wrapper in
                    wrapper.finishContinuation(id: requestID, with: data)
                }
            }
        }
    }

    package func addRateLimit(
        bundleIdentifier: String?,
        featureIdentifier: String?,
        workloadType: String?,
        count: UInt,
        duration: Double,
        ttl: Double,
        jitter: Double
    ) async throws {
        let requestID = self.nextRequestID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.storeContinuation(continuation, id: requestID)

            self.xpc.addRateLimit(
                bundleIdentifier: bundleIdentifier,
                featureIdentifier: featureIdentifier,
                workloadType: workloadType,
                count: count,
                duration: duration,
                ttl: ttl,
                jitter: jitter
            ) {
                self.assumeIsolated { wrapper in
                    wrapper.finishContinuation(id: requestID)
                }
            }
        }
    }

    package func resetRateLimits() async throws {
        let requestID = self.nextRequestID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.storeContinuation(continuation, id: requestID)

            self.xpc.resetRateLimits {
                self.assumeIsolated { wrapper in
                    wrapper.finishContinuation(id: requestID)
                }
            }
        }
    }

    package func fetchServerDrivenConfiguration() async throws -> Data {
        let requestID = self.nextRequestID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            self.storeContinuation(continuation, id: requestID)

            self.xpc.fetchServerDrivenConfiguration { data in
                self.assumeIsolated { wrapper in
                    wrapper.finishContinuation(id: requestID, with: data)
                }
            }
        }
    }

    package func listServerDrivenConfiguration() async throws -> Data {
        let requestID = self.nextRequestID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            self.storeContinuation(continuation, id: requestID)

            self.xpc.listServerDrivenConfiguration { data in
                self.assumeIsolated { wrapper in
                    wrapper.finishContinuation(id: requestID, with: data)
                }
            }
        }
    }

    package func setServerDrivenConfiguration(json: Data) async throws -> Data {
        let requestID = self.nextRequestID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            self.storeContinuation(continuation, id: requestID)

            self.xpc.setServerDrivenConfiguration(json: json) { data in
                self.assumeIsolated { wrapper in
                    wrapper.finishContinuation(id: requestID, with: data)
                }
            }
        }
    }

    // MARK: Trusted request proxy methods

    package func cancel(connectionID: Int, proxy: any TC2XPCTrustedRequestProtocol) async {
        guard self.connectionID == connectionID else { return }
        proxy.cancel {}
    }

    package func close(connectionID: Int, proxy: any TC2XPCTrustedRequestProtocol) async {
        guard self.connectionID == connectionID else { return }
        proxy.close {}
    }

    package func send(connectionID: Int, proxy: any TC2XPCTrustedRequestProtocol, message: XPCRequestMessage) async throws {
        guard self.connectionID == connectionID else {
            // check that the xpc connection for which we received the proxy object is still alive
            throw PrivateCloudComputeError(code: .xpcConnectionInterrupted)
        }
        let data = message.json
        let xpcRequestID = self.nextRequestID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.storeContinuation(continuation, id: xpcRequestID)

            proxy.send(data: data) { (errorData) in
                self.assumeIsolated { wrapper in
                    if let errorData {
                        if let error = PrivateCloudComputeError(json: errorData) {
                            wrapper.failContinuation(id: xpcRequestID, error: error)
                        } else {
                            let error = PrivateCloudComputeError(message: "failed to send and decode error")
                            wrapper.failContinuation(id: xpcRequestID, error: error)
                        }
                    } else {
                        wrapper.finishContinuation(id: xpcRequestID)
                    }
                }
            }
        }
    }

    package func next(connectionID: Int, proxy: any TC2XPCTrustedRequestProtocol) async throws -> XPCResponseMessage? {
        guard self.connectionID == connectionID else {
            // check that the xpc connection for which we received the proxy object is still alive
            throw PrivateCloudComputeError(code: .xpcConnectionInterrupted)
        }
        let xpcRequestID = self.nextRequestID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<XPCResponseMessage?, any Error>) in
            self.storeContinuation(continuation, id: xpcRequestID)

            proxy.next { (responseData, errorData) in
                self.assumeIsolated { wrapper in
                    if let errorData {
                        if let error = PrivateCloudComputeError(json: errorData) {
                            wrapper.failContinuation(id: xpcRequestID, error: error)
                        } else {
                            let error = PrivateCloudComputeError(message: "failed to get next and decode error")
                            wrapper.failContinuation(id: xpcRequestID, error: error)
                        }
                    } else {
                        if let responseData {
                            if let message = XPCResponseMessage(json: responseData) {
                                wrapper.finishContinuation(id: xpcRequestID, with: message)
                            } else {
                                let error = PrivateCloudComputeError(message: "failed to decode response message")
                                wrapper.failContinuation(id: xpcRequestID, error: error)
                            }
                        } else {
                            // receiving completed
                            wrapper.finishContinuation(id: xpcRequestID, with: nil as XPCResponseMessage?)
                        }
                    }
                }
            }
        }
    }

    package func createSubrequest(
        connectionID: Int,
        proxy: any TC2XPCTrustedRequestProtocol,
        subrequest: XPCSubrequest
    ) async throws {
        guard self.connectionID == connectionID else {
            // check that the xpc connection for which we received the proxy object is still alive
            throw PrivateCloudComputeError(code: .xpcConnectionInterrupted)
        }
        let data = subrequest.json
        let xpcRequestID = self.nextRequestID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.storeContinuation(continuation, id: xpcRequestID)

            proxy.createSubrequest(request: data) { (errorData) in
                self.assumeIsolated { wrapper in
                    if let errorData {
                        if let error = PrivateCloudComputeError(json: errorData) {
                            wrapper.failContinuation(id: xpcRequestID, error: error)
                        } else {
                            let error = PrivateCloudComputeError(message: "failed to createSubrequest and decode error")
                            wrapper.failContinuation(id: xpcRequestID, error: error)
                        }
                    } else {
                        wrapper.finishContinuation(id: xpcRequestID)
                    }
                }
            }
        }
    }

    package func nextProgress(connectionID: Int, proxy: any TC2XPCTrustedRequestProtocol) async throws -> PrivateCloudComputeConnection.Progress? {
        guard self.connectionID == connectionID else {
            // check that the xpc connection for which we received the proxy object is still alive
            throw PrivateCloudComputeError(code: .xpcConnectionInterrupted)
        }
        let xpcRequestID = self.nextRequestID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PrivateCloudComputeConnection.Progress?, any Error>) in
            self.storeContinuation(continuation, id: xpcRequestID)

            proxy.nextProgress { responseData in
                self.assumeIsolated { wrapper in
                    if let responseData {
                        if let message = PrivateCloudComputeConnection.Progress(json: responseData) {
                            wrapper.finishContinuation(id: xpcRequestID, with: message)
                        } else {
                            let error = PrivateCloudComputeError(message: "failed to decode progress update")
                            wrapper.failContinuation(id: xpcRequestID, error: error)
                        }
                    } else {
                        // receiving completed
                        wrapper.finishContinuation(id: xpcRequestID, with: nil as XPCResponseMessage?)
                    }
                }
            }
        }

    }

    // MARK: - Private Methods -

    private func nextRequestID() -> Int {
        defer { self._nextRequestID += 1 }
        return self._nextRequestID
    }

    private func nextConnectionID() -> Int {
        defer { self._nextConnectionID += 1 }
        return self._nextConnectionID
    }

    private func failAllRunningRequestsAndRestartConnection() {

        // fail all running requests
        for (_, continuation) in self.runningRequests {
            continuation.resume(throwing: PrivateCloudComputeError(code: .xpcConnectionInterrupted))
        }
        self.runningRequests.removeAll(keepingCapacity: true)

        // create new connection
        let newConnection = NSXPCConnection(machServiceName: "com.apple.privatecloudcompute")
        #if os(macOS)
        if let userID { newConnection._setTargetUserIdentifier(userID) }
        #endif

        newConnection._setQueue(self.queue)
        newConnection.remoteObjectInterface = interfaceForTC2DaemonProtocol()
        newConnection.interruptionHandler = {
            self.assumeIsolated { wrapper in
                wrapper.failAllRunningRequestsAndRestartConnection()
            }
        }
        newConnection.resume()

        let oldConnection = self.connection
        self.connection = newConnection
        self.connectionID = self.nextConnectionID()
        self.xpc = newConnection.remoteObjectProxy as! (any TC2DaemonProtocol)

        // We release the old connection here, hoping that this will release all captured callback
        // blocks
        oldConnection.interruptionHandler = nil
        oldConnection.invalidationHandler = nil
        oldConnection.invalidate()

        // We want to crash here! If the `remoteObjectProxy` does not conform to `TC2DaemonProtocol`
        // the framework and deamon have gotten out of sync. This is an irrecoverable error anyway.
        self.xpc = self.connection.remoteObjectProxy as! (any TC2DaemonProtocol)
    }

    // MARK: Storing and retrieving Continuation

    private func storeContinuation(_ checkedContinuation: CheckedContinuation<Void, any Error>, id: Int) {
        self.runningRequests[id] = .void(checkedContinuation)
    }

    private func finishContinuation(id: Int) {
        guard let continuation = self.runningRequests.removeValue(forKey: id) else {
            return  // race.
        }

        switch continuation {
        case .bool, .optionalData, .data, .string, .stringArray, .requestProxy, .optionalResponseMessage, .optionalProgress:
            fatalError()
        case .void(let continuation):
            continuation.resume(returning: ())
        }
    }

    private func storeContinuation(_ checkedContinuation: CheckedContinuation<Bool, any Error>, id: Int) {
        self.runningRequests[id] = .bool(checkedContinuation)
    }

    private func finishContinuation(id: Int, with result: Bool) {
        guard let continuation = self.runningRequests.removeValue(forKey: id) else {
            return  // race.
        }

        switch continuation {
        case .void, .optionalData, .data, .string, .stringArray, .requestProxy, .optionalResponseMessage, .optionalProgress:
            fatalError()
        case .bool(let continuation):
            continuation.resume(returning: result)
        }
    }

    private func storeContinuation(_ checkedContinuation: CheckedContinuation<Data, any Error>, id: Int) {
        self.runningRequests[id] = .data(checkedContinuation)
    }

    private func finishContinuation(id: Int, with data: Data) {
        guard let continuation = self.runningRequests.removeValue(forKey: id) else {
            return  // race.
        }

        switch continuation {
        case .void, .bool, .optionalData, .string, .stringArray, .requestProxy, .optionalResponseMessage, .optionalProgress:
            fatalError()
        case .data(let continuation):
            continuation.resume(returning: data)
        }
    }

    private func storeContinuation(_ checkedContinuation: CheckedContinuation<Data?, any Error>, id: Int) {
        self.runningRequests[id] = .optionalData(checkedContinuation)
    }

    private func finishContinuation(id: Int, with data: Data?) {
        guard let continuation = self.runningRequests.removeValue(forKey: id) else {
            return  // race.
        }

        switch continuation {
        case .void, .bool, .data, .string, .stringArray, .requestProxy, .optionalResponseMessage, .optionalProgress:
            fatalError()
        case .optionalData(let continuation):
            continuation.resume(returning: data)
        }
    }

    private func storeContinuation(_ checkedContinuation: CheckedContinuation<String, any Error>, id: Int) {
        self.runningRequests[id] = .string(checkedContinuation)
    }

    private func finishContinuation(id: Int, with string: String) {
        guard let continuation = self.runningRequests.removeValue(forKey: id) else {
            return  // race.
        }

        switch continuation {
        case .void, .bool, .data, .stringArray, .optionalData, .requestProxy, .optionalResponseMessage, .optionalProgress:
            fatalError()
        case .string(let continuation):
            continuation.resume(returning: string)
        }
    }

    private func storeContinuation(_ checkedContinuation: CheckedContinuation<[String], any Error>, id: Int) {
        self.runningRequests[id] = .stringArray(checkedContinuation)
    }

    private func finishContinuation(id: Int, with array: [String]) {
        guard let continuation = self.runningRequests.removeValue(forKey: id) else {
            return  // race.
        }

        switch continuation {
        case .void, .bool, .data, .string, .optionalData, .requestProxy, .optionalResponseMessage, .optionalProgress:
            fatalError()
        case .stringArray(let continuation):
            continuation.resume(returning: array)
        }
    }

    private func storeContinuation(_ checkedContinuation: CheckedContinuation<(any TC2XPCTrustedRequestProtocol, Int), any Error>, id: Int) {
        self.runningRequests[id] = .requestProxy(checkedContinuation)
    }

    private func finishContinuation(id: Int, with proxy: any TC2XPCTrustedRequestProtocol, connectionID: Int) {
        guard let continuation = self.runningRequests.removeValue(forKey: id) else {
            return  // race.
        }

        switch continuation {
        case .void, .bool, .data, .string, .optionalData, .stringArray, .optionalResponseMessage, .optionalProgress:
            fatalError()
        case .requestProxy(let continuation):
            continuation.resume(returning: (proxy, connectionID))
        }
    }

    private func storeContinuation(_ checkedContinuation: CheckedContinuation<XPCResponseMessage?, any Error>, id: Int) {
        self.runningRequests[id] = .optionalResponseMessage(checkedContinuation)
    }

    private func finishContinuation(id: Int, with message: XPCResponseMessage?) {
        guard let continuation = self.runningRequests.removeValue(forKey: id) else {
            return  // race.
        }

        switch continuation {
        case .void, .bool, .data, .optionalData, .string, .stringArray, .requestProxy, .optionalProgress:
            fatalError()
        case .optionalResponseMessage(let continuation):
            continuation.resume(returning: message)
        }
    }

    private func storeContinuation(_ checkedContinuation: CheckedContinuation<PrivateCloudComputeConnection.Progress?, any Error>, id: Int) {
        self.runningRequests[id] = .optionalProgress(checkedContinuation)
    }

    private func finishContinuation(id: Int, with message: PrivateCloudComputeConnection.Progress?) {
        guard let continuation = self.runningRequests.removeValue(forKey: id) else {
            return  // race.
        }

        switch continuation {
        case .void, .bool, .data, .optionalData, .string, .stringArray, .requestProxy, .optionalResponseMessage:
            fatalError()
        case .optionalProgress(let continuation):
            continuation.resume(returning: message)
        }
    }

    private func failContinuation(id: Int, error: any Error) {
        guard let continuation = self.runningRequests.removeValue(forKey: id) else {
            return  // race.
        }

        switch continuation {
        case .void(let continuation):
            continuation.resume(throwing: error)
        case .bool(let continuation):
            continuation.resume(throwing: error)
        case .data(let continuation):
            continuation.resume(throwing: error)
        case .string(let continuation):
            continuation.resume(throwing: error)
        case .optionalData(let continuation):
            continuation.resume(throwing: error)
        case .stringArray(let continuation):
            continuation.resume(throwing: error)
        case .requestProxy(let continuation):
            continuation.resume(throwing: error)
        case .optionalResponseMessage(let continuation):
            continuation.resume(throwing: error)
        case .optionalProgress(let continuation):
            continuation.resume(throwing: error)
        }
    }
}
