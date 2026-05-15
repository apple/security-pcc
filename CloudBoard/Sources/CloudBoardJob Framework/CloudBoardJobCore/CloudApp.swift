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

internal import CloudBoardCommon
import CloudBoardDomain
import CloudBoardJobAPI
internal import CloudBoardLogging
internal import CloudBoardOSActivity
internal import CloudBoardCommon
internal import Synchronization
import CloudBoardDomain
import Foundation
import os

private let log: Logger = .init(
    subsystem: "com.apple.cloudos.cloudboard",
    category: "CloudBoardJob"
)

public struct InputData: AsyncSequence, Sendable {
    let dataInputStream: AsyncStream<Data>
    public typealias Element = Data

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncStream<Data>.AsyncIterator

        public mutating func next() async throws -> Element? {
            await self.iterator.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: self.dataInputStream.makeAsyncIterator())
    }
}

private typealias DataOutputContinuation = AsyncStream<Data>.Continuation
/// This exists solely to retain ABI compatibility on ``ResponseWriter`` which was declared a struct,
/// but should have reference semantics, and which needs to be properly Sendable
package final class ResponseWriterRef: Sendable {
    private let (outputStream, outputContinuation) = AsyncStream<Data>.makeStream()
    private let xpcMessenger: JobHelperMessenger
    private let finished = Mutex<Bool>(false)
    init(messenger: JobHelperMessenger) {
        self.xpcMessenger = messenger
    }

    func run() async throws {
        for await data in self.outputStream {
            try await self.xpcMessenger.provideOutput(data)
        }
        try await self.xpcMessenger.endOfResponse()
    }

    public func write(_ output: Data) async throws {
        self.outputContinuation.yield(output)
    }

    public func finish() {
        self.finished.withLock {
            $0 = true
        }
        self.outputContinuation.finish()
    }

    public func finish(_ error: CloudAppRequestExecutionError) async {
        await self.xpcMessenger.reportCloudAppRequestExecutionError(error: error)
        self.finish()
    }

    package func forceFinished() async {
        let treatAsError = self.finished.withLock { !$0 }
        // It's important to get the endOfResponse message out before the finish.
        // There is a race between this check and a potential call to finish()
        // but the scenarios where this would be called, and it wasn't finished, are
        // failure cases where it's highly unlikely any subsequent finish will happen.
        // Even if this results in loss of response chunk messages it's not a problem
        // because this will be terminating the PCC layer (as an error) anyway
        if treatAsError {
            await self.xpcMessenger.internalError()
        }
        self.finish()
    }
}

/// Information available at warmup.
/// Some is duplicated in '``CloudAppEnvironment`` and is guaranteed to not change
public struct WarmupEnvironment: Sendable {
    /// In most cases a CloudApp already knows it's name, but when being replaced by
    /// the ``ShadowTunnelCloudApp`` it helps to know it
    package var cloudAppName: String

    // Additional properties could be added for little cost, such as ensembleInstanceID
    // and rackID but we only add the things needed right now

    /// Launchd job instance UUID shared across all associated per-request processes.
    /// This can be used to connect to a support app launched and managed by CloudBoard.
    public var launchdJobInstanceUUID: UUID

    /// The metadata of all assets that are available to the cloud app.
    public var assetsMetadata: [AssetMetadata]
}

/// Despite being a struct this has reference semantics
public struct ResponseWriter: Sendable {
    package let ref: ResponseWriterRef

    init(messenger: JobHelperMessenger) {
        self.ref = ResponseWriterRef(messenger: messenger)
    }

    func run() async throws {
        try await self.ref.run()
    }

    public func write(_ output: Data) async throws {
        try await self.ref.write(output)
    }

    public func finish() throws {
        self.ref.finish()
    }

    public func finish(_ error: CloudAppRequestExecutionError) async {
        await self.ref.finish(error)
    }
}

@preconcurrency
public protocol CloudBoardApp: Sendable {
    init()
    /// If there is expensive work which can be deferred till after init, but which must be done before
    /// ``run(input:responder:environment:)`` it can be done here
    /// If a cloud app wants to implement this they only need to implement one, and should prefer
    /// to override the ``warmup(environment:)`` implementation.
    @available(*, deprecated, renamed: "warmup(environment:)", message: "Please move to the new signature")
    func warmup() async throws
    /// If there is expensive work which can be deferred till after init, but which must be done before
    /// ``run(input:responder:environment:)`` it can be done here
    func warmup(environment: WarmupEnvironment) async throws
    /// Performs any necessary teardown work.
    /// Returning from this function signals acknowledgement of the
    /// teardown request. The run() routine will be cancelled after this function
    /// returns.
    func teardown() async throws
    /// Handle the request.
    /// this will be called only once (and may never be called if the cloud app is never used
    /// for an actual request.
    /// - Parameters:
    ///   - input: A stream of data from the client.
    ///   This will contain nothing and immediately terminate if
    ///   ``CloudAppEnvironment/requestBypassed`` is true
    ///   - responder: A means to respond to the request
    ///   - environment: A means for the cloud app to be aware of components of the system managed
    ///   for it, and some information about the request which is not directly taken from the input
    func run(
        input: InputData,
        responder: ResponseWriter,
        environment: CloudAppEnvironment
    ) async throws
}

extension CloudBoardApp {
    public func warmup() async throws {
        // Can be overridden by implementing type...
    }

    public func warmup(environment _: WarmupEnvironment) async throws {
        // Can be overridden by implementing type,
        // if they only overrode the overload without the environment keep that path working
        try await self.warmup()
    }

    public func teardown() async throws {
        // Returning from this function signals acknowledgement of the
        // teardown request. The run() routine will be cancelled after this function
        // returns.
    }
}

extension CloudBoardApp {
    /// Convenience boostrapping based on the type and an empty initialiser
    package static func bootstrap(
        server: CloudBoardJobAPIServerProtocol,
        metricsBuilder: CloudAppMetrics.Builder
    ) async throws {
        try await CloudBoardAppRunner.bootstrap(
            appInstance: Self(),
            server: server,
            metricsBuilder: metricsBuilder
        )
    }
}

package enum CloudBoardAppRunner {
    package static func bootstrap(
        appInstance: some CloudBoardApp,
        server: CloudBoardJobAPIServerProtocol,
        metricsBuilder: CloudAppMetrics.Builder
    ) async throws {
        let (subrequestStream, subrequestContinuation) = AsyncStream<SubrequestExecution>.makeStream()
        // Create the stream and associated continuation to forward teardown requests
        let (teardownRequestStream, teardownRequestStreamContinuation) = AsyncStream<Void>.makeStream()

        // the intention here is to just touch the `log` logger early on bootstrap to avoid any lazy initialization
        log.debug("Bootstrapping app \(type(of: appInstance))")

        let xpcMessenger = await JobHelperMessenger(
            server: server,
            subrequestContinuation: subrequestContinuation,
            teardownContinuation: teardownRequestStreamContinuation,
            log: log,
            appInstance: appInstance,
            metricsBuilder: metricsBuilder
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let parameters: ParametersData
                do {
                    try await xpcMessenger.waitForWarmupComplete()
                    parameters = try await xpcMessenger.waitForParameters()
                } catch {
                    try await xpcMessenger.endJob()
                    throw error
                }

                if let subrequestProxyInstance = appInstance as? SubrequestProxyApp {
                    try await Self.runSubrequestProxyApp(
                        subrequestProxyInstance: subrequestProxyInstance,
                        xpcMessenger: xpcMessenger,
                        parameters: parameters,
                        subrequestStream: subrequestStream
                    )
                } else {
                    try await Self.runCloudApp(
                        appInstance: appInstance,
                        xpcMessenger: xpcMessenger,
                        parameters: parameters,
                        subrequestStream: subrequestStream,
                        subrequestContinuation: subrequestContinuation
                    )
                }
            }

            group.addTask {
                for await _ in teardownRequestStream {}
                if !Task.isCancelled {
                    log.info("Tearing down Cloud app")
                    try await appInstance.teardown()
                }
            }

            // If one of these terminates, we want to cancel the other.
            _ = try await group.next()
            log.info("Cancelling all subtasks")
            await xpcMessenger.cancel()
            group.cancelAll()
        }
    }

    private static func runSubrequestProxyApp(
        subrequestProxyInstance: SubrequestProxyApp,
        xpcMessenger: JobHelperMessenger,
        parameters: ParametersData,
        subrequestStream: AsyncStream<SubrequestExecution>
    ) async throws {
        let environment = await Self.createProxyAppEnvironment(
            parameters: parameters,
            xpcMessenger: xpcMessenger
        )
        logMessage("CloudBoardJob invoked", environment: environment)

        do {
            try await subrequestProxyInstance.run(
                subrequestExecutionStream: .init(requestInputStream: subrequestStream),
                environment: environment
            )
        } catch {
            await self.handleError(error: error, xpcMessenger: xpcMessenger, environment: environment)
            try await xpcMessenger.endJob()
            throw error
        }
        try await xpcMessenger.endJob()
    }

    private static func handleError(
        error: Error,
        xpcMessenger: JobHelperMessenger,
        environment: LoggableEnvironment
    ) async {
        logError(error, environment: environment)

        if let requestExecutionError = error as? RequestExecutionErrorProtocol {
            await xpcMessenger.reportRequestExecutionError(error: requestExecutionError)
        }
        await xpcMessenger.internalError()
    }

    private static func runCloudApp(
        appInstance: CloudBoardApp,
        xpcMessenger: JobHelperMessenger,
        parameters: ParametersData,
        subrequestStream: AsyncStream<SubrequestExecution>,
        subrequestContinuation: AsyncStream<SubrequestExecution>.Continuation
    ) async throws {
        /// Fabricate a sub request for CloudBoardApps
        /// which don't implement SubrequestProxyApp
        try await xpcMessenger.fabricateClientSubrequest()
        subrequestContinuation.finish()

        try await withThrowingTaskGroup(of: Void.self) { subrequestGroup in
            /// We expect to receive only one sub request here
            if let subrequestExecution = await subrequestStream.first(where: { _ in true }) {
                let (inputStream, inputContinuation) = AsyncStream<Data>.makeStream()
                let responseWriter = ResponseWriter(messenger: xpcMessenger)
                if parameters.requestBypassed {
                    inputContinuation.finish()
                } else {
                    subrequestGroup.addTask {
                        for try await event in subrequestExecution.events {
                            switch event {
                            case .subrequestStart, .subrequestEnd, .subrequestCancellation:
                                // We ignore these for old-style run implementations
                                ()
                            case .subrequestPayload(let payload):
                                inputContinuation.yield(payload.data)
                            }
                        }
                        inputContinuation.finish()
                    }
                }
                subrequestGroup.addTask {
                    try await responseWriter.run()
                }

                subrequestGroup.addTask {
                    let environment = await Self.createCloudAppEnvironment(
                        parameters: parameters,
                        xpcMessenger: xpcMessenger,
                        pccClient: subrequestExecution.pccClient
                    )
                    do {
                        logMessage("CloudBoardJob invoked", environment: environment)
                        try await appInstance.run(
                            input: .init(dataInputStream: inputStream),
                            responder: responseWriter,
                            environment: environment
                        )
                        // We need to ensure the responseWriter is finished.
                        // It is the job of the real CloudApp to do this properly for the request
                        // to be considered a success,
                        // If this forceFinished will trigger finish it first sends the
                        // internalError message to ensure that arrives first
                        await responseWriter.ref.forceFinished()
                    } catch {
                        // if the response to the client was completed this cannot change that
                        // but having it enhances observability, and potentially can be passed upwards
                        // to ROPES in future
                        // we need to terminate the response writer run loop to make progress
                        await self.handleError(error: error, xpcMessenger: xpcMessenger, environment: environment)
                        responseWriter.ref.finish()
                        throw error
                    }
                }
            }
            var endJobCalled = false
            do {
                try await subrequestGroup.waitForAll()
                endJobCalled = true
                try await xpcMessenger.endJob()
            } catch {
                if !endJobCalled {
                    try await xpcMessenger.endJob()
                }
                throw error
            }
        }
    }

    private static func createCloudAppEnvironment(
        parameters: ParametersData,
        xpcMessenger: JobHelperMessenger,
        pccClient: PCCClient
    ) async -> CloudAppEnvironment {
        let metrics = await xpcMessenger.buildMetrics()
        let keyDerivationHelper = KeyDerivationHelper(
            jobHelperMessenger: xpcMessenger,
            clientRequestID: parameters.plaintextMetadata.requestID
        )
        let appData = parameters.nodeAppData
        // EnsembleId, bootId and rackId need to default to empty string for now, we can
        // eliminate optionals
        // once we're certain these values won't be empty and are being populated 100% of the
        // time.
        let ensembleInstanceID = EnsembleInstanceId(
            ensembleId: appData.ensembleID?.utf8String ?? "",
            bootId: appData.bootID?.utf8String ?? ""
        )
        let rackID = RackId(appData.rackID?.utf8String ?? "")
        return CloudAppEnvironment(
            metrics: metrics,
            plaintextMetadata: .init(parameters.plaintextMetadata),
            pccClient: pccClient,
            pirClient: PrivateInformationRetrievalClient(
                jobHelperMessenger: xpcMessenger,
                pccServerRequestID: parameters.plaintextMetadata.requestID,
                traceID: UUID(uuidString: parameters.traceContext.traceID) ?? UUID(),
                defaultParentSpanID: parameters.traceContext.spanID
            ),
            keyDerivation: keyDerivationHelper,
            requestBypassed: parameters.requestBypassed,
            traceContext: .init(parameters.traceContext),
            updatedTraceContext: .init(parameters.traceContext),
            ensembleInstanceID: ensembleInstanceID,
            rackID: rackID,
            launchdJobInstanceUUID: parameters.launchdJobInstanceUUID,
            supportApps: parameters.supportApps
        )
    }

    private static func createProxyAppEnvironment(
        parameters: ParametersData,
        xpcMessenger: JobHelperMessenger
    ) async -> ProxyAppEnvironment {
        let metrics = await xpcMessenger.buildMetrics()
        let keyDerivationHelper = KeyDerivationHelper(
            jobHelperMessenger: xpcMessenger,
            clientRequestID: parameters.plaintextMetadata.requestID
        )
        let appData = parameters.nodeAppData
        // EnsembleId, bootId and rackId need to default to empty string for now, we can
        // eliminate optionals
        // once we're certain these values won't be empty and are being populated 100% of the
        // time.
        let ensembleInstanceID = EnsembleInstanceId(
            ensembleId: appData.ensembleID?.utf8String ?? "",
            bootId: appData.bootID?.utf8String ?? ""
        )
        let rackID = RackId(appData.rackID?.utf8String ?? "")
        return ProxyAppEnvironment(
            metrics: metrics,
            plaintextMetadata: .init(parameters.plaintextMetadata),
            pirClient: PrivateInformationRetrievalClient(
                jobHelperMessenger: xpcMessenger,
                pccServerRequestID: parameters.plaintextMetadata.requestID,
                traceID: UUID(uuidString: parameters.traceContext.traceID) ?? UUID(),
                defaultParentSpanID: parameters.traceContext.spanID
            ),
            keyDerivation: keyDerivationHelper,
            requestBypassed: parameters.requestBypassed,
            updatedTraceContext: .init(parameters.traceContext),
            ensembleInstanceID: ensembleInstanceID,
            rackID: rackID,
            launchdJobInstanceUUID: parameters.launchdJobInstanceUUID,
            supportApps: parameters.supportApps
        )
    }
}

extension CloudAppEnvironment.PlaintextMetadata {
    init(_ receivedData: ParametersData.PlaintextMetadata?) {
        if let receivedData {
            self.init(
                bundleID: receivedData.bundleID,
                bundleVersion: receivedData.bundleVersion,
                featureID: receivedData.featureID,
                clientInfo: receivedData.clientInfo,
                workloadType: receivedData.workloadType,
                workloadParameters: receivedData.workloadParameters,
                requestID: receivedData.requestID,
                automatedDeviceGroup: receivedData.automatedDeviceGroup
            )
        } else {
            self.init(
                bundleID: "",
                bundleVersion: "",
                featureID: "",
                clientInfo: "",
                workloadType: "",
                workloadParameters: [:],
                requestID: "",
                automatedDeviceGroup: ""
            )
        }
    }
}

// Trace Context with String representation of spanID
extension CloudAppEnvironment.TraceContext {
    init(_ receivedData: CloudBoardTraceContext?) {
        if let receivedData {
            self.init(
                traceID: receivedData.traceID,
                spanID: receivedData.spanID.hexEncoded
            )
        } else {
            self.init(
                traceID: "",
                spanID: ""
            )
        }
    }
}

// Trace Context with UInt64 representation of spanID
extension CloudAppEnvironment.UpdatedTraceContext {
    init(_ receivedData: CloudBoardTraceContext?) {
        if let receivedData {
            self.init(
                traceID: receivedData.traceID,
                spanID: receivedData.spanID
            )
        } else {
            self.init(
                traceID: "",
                spanID: UInt64.random(in: 0 ..< UInt64.max)
            )
        }
    }
}

private protocol LoggableEnvironment {
    var plaintextMetadata: CloudAppEnvironment.PlaintextMetadata { get }
    var requestBypassed: Bool { get }
    var updatedTraceContext: CloudAppEnvironment.UpdatedTraceContext { get }
}

extension CloudAppEnvironment: LoggableEnvironment {}
extension ProxyAppEnvironment: LoggableEnvironment {}

extension CloudBoardAppRunner {
    private static func logMessage(_ message: StaticString, environment: some LoggableEnvironment) {
        log.log("""
        message=\(message, privacy: .public)
        request.uuid=\(environment.plaintextMetadata.requestID, privacy: .public)
        bundleID=\(environment.plaintextMetadata.bundleID, privacy: .public)
        bundleVersion=\(environment.plaintextMetadata.bundleVersion, privacy: .public)
        featureID=\(environment.plaintextMetadata.featureID, privacy: .public)
        automatedDeviceGroup=\(
            environment.plaintextMetadata.automatedDeviceGroup,
            privacy: .public
        )
        clientInfo=\(environment.plaintextMetadata.clientInfo, privacy: .public)
        requestBypassed=\(environment.requestBypassed, privacy: .public)
        traceID=\(environment.updatedTraceContext.traceID, privacy: .public)
        spanID=\(environment.updatedTraceContext.spanID, privacy: .public)
        """)
    }

    private static func logError(_ error: Error, environment: some LoggableEnvironment) {
        log.error("""
        Cloud app failed with error=\(String(reportable: error), privacy: .public)
        request.uuid=\(environment.plaintextMetadata.requestID, privacy: .public)
        bundleID=\(environment.plaintextMetadata.bundleID, privacy: .public)
        bundleVersion=\(environment.plaintextMetadata.bundleVersion, privacy: .public)
        featureID=\(environment.plaintextMetadata.featureID, privacy: .public)
        automatedDeviceGroup=\(
            environment.plaintextMetadata.automatedDeviceGroup,
            privacy: .public
        )
        clientInfo=\(environment.plaintextMetadata.clientInfo, privacy: .public)
        requestBypassed=\(environment.requestBypassed, privacy: .public)
        traceID=\(environment.updatedTraceContext.traceID, privacy: .public)
        spanID=\(environment.updatedTraceContext.spanID, privacy: .public)
        """)
    }
}
