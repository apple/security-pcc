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

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Top level CloudApp protocol.
///
/// Example implementation of the simples possible CloudApp is pasted below. See the documentation of the `CloudApp*` types for the explanation of the detailed semantics.
///
///@main
///struct MyFirstCloudApp: CloudApp {
///    init() {
///    }
///
///    func run(process: CloudAppProcess) async throws {
///        // Perform warmup
///
///        // Create the service. We could pass the `process` to observe early shutdown signals
///        let service = MyFirstCloudAppService()
///
///        // Hand over a service for execution. `execute` will only exit once the request handling is fully completed.
///        try await process.execute(service: service)
///
///        // Perform shutdown.
///    }
///}
///
///struct MyFirstCloudAppService: CloudAppService {
///    func request(
///        input: InputData,
///        output: ResponseWriter,
///        requestContext: RequestContext
///    ) async throws -> ObservabilityResult {
///        // Handle request
///        return .success
///    }
///
///    // The default implementation of `earlyShutdown` cancels the outstanding `Task`-s executing  `request(input:output:requestContext:)`.
///    // That default implementation can be overridden. At that point number of different APIs exist to observe the early shutdown, including:
///    // * `CloudAppProcess.withEarlyShutdownHandler`
///    // * `CloudAppProcess.isShuttingDownEarly`
///    func earlyShutdown() {
///        // custom handling of the shutdown
///    }
///}
///
public protocol CloudApp: Sendable {
    /// Implementations may perform initialisation within the init as they require,
    /// It is expected that many adopters will need additional information to fully "prewarm"
    /// themselves (become as ready as possible to handle a request without knowing the specific
    /// request yet)
    init()

    /// The runtime will execute the `CloudApp.run` and all the requests are handled within it.
    ///
    /// This will be exececuted once and only once.
    ///
    /// `CloudApp` gets to control the prewarm and shutdown phase before and after the request handling phase
    ///     * prewarm completes, when the `CloudApp` hands over a `CloudAppService` for execution via ``CloudAppProcess/execute``
    ///     * shutdown starts after the service execution finishes, which in turn happens when the outstanding request handling completes
    ///
    /// Errors thrown out of the `run` are considered to be infrastructural errors, and won't be reflected back to the remote peer.
    ///
    /// - parameter process: Listens for service registration, and exposes early shutdown signal
    func run(process: CloudAppProcess) async throws
}

public final class CloudAppProcess: Sendable {
    private struct ShutdownState: ~Copyable {
        var isShuttingDownEarly: Bool
        var shutdownHandlers: [@Sendable () -> Void]

        init() {
            self.isShuttingDownEarly = false
            self.shutdownHandlers = []
        }
    }

    public let warmupContext: WarmupContext
    private let stateMachine: CloudAppStateMachine
    private let requestSequence: AsyncStream<ExecutionNotification>
    private let shutdownState = Mutex(ShutdownState())

    enum Errors: ReportableError {
        case multipleServiceExecutionsUnsupported

        var publicDescription: String {
            switch self {
            case .multipleServiceExecutionsUnsupported:
                "Error due to attempt to execute multiple services."
            }
        }
    }

    enum ExecutionNotification: Sendable {
        case request(CloudAppRequest)
        case shutdownEarly
    }

    init(
        warmupContext: WarmupContext,
        stateMachine: CloudAppStateMachine,
        requestSequence: AsyncStream<ExecutionNotification>
    ) {
        self.warmupContext = warmupContext
        self.stateMachine = stateMachine
        self.requestSequence = requestSequence
    }

    /// When `execute` is invoked, the runtime waits for requests to be assigned to this process, and then deliver them to the service's `request(input:output:requestContext:)`
    ///
    /// Adopters MUST
    /// * Call this once
    /// * Be ready to handle a request when they do
    ///
    /// Adopters SHOULD rely on the following implementation details:
    /// * If a request is handled by this instance then ``CloudAppService/request`` will be called once and only once
    ///
    /// For full details on the error handling see the documentation for ``CloudAppService/request``
    /// The execution continues until after the request execution has completed fully.
    /// During this phase ``CloudAppService/earlyShutdown()`` may be called to indicate that there is no point continuing
    /// (most likely the client connection broke) see CloudAppService docs for more details.
    ///
    /// ## Cleanup
    /// The intended reasons to perform any work after execute finishes (by which point the request is entirely handled from
    /// the point of view of the initiator) are covered by:
    ///
    /// ### Observability: e.g. logging
    /// Adopters SHOULD assume the platform logs the relevant state transitions and need not duplicate them
    ///
    /// ### Releasing/Erasing of state shared across requests
    /// In cases where the CloudApp shares/takes exclusive access of a resource outisde the process it is likely that
    /// there is work to do cleaning up after the current request is complete, before allowing a new request to happen.
    /// That new request will happen in a separate CloudApp process, but the current cloud app waits for the
    /// cleanup to happen then returns from run to indicates that this is complete and that any resources consumed by the
    /// request are freely available for use.
    /// There are limits on how long this wait can be, but they are measuresd in seconds, if this is a problem for your use case talk to the
    /// data plane team
    ///
    /// Since panic failure modes exist no matter what the Adopter should ensure that the system will function
    /// correctly and *safely* even if the intended cleanup does not run (but this may be less efficient).
    public func execute(service: any CloudAppService) async throws {
        let possibleDirectAction = self.stateMachine.advancePotentiallyConsumingTheActionDirectly {
            let action = $0.warmupCompleted(service: service)
            if case .rejectCloudAppService = action {
                return .consumeDirectly(action)
            }
            return .consumeAsynchronously(action)
        }

        if let directAction = possibleDirectAction {
            guard case .rejectCloudAppService(let reason) = directAction else {
                fatalError("Should only be handling .rejectCloudAppService")
            }
            switch reason {
            case .cloudBoardRPCError:
                // In normal cases we'll end up here due to RPC error, and we want to handle this as closely to how this is done if the RPC error happened little later on
                // However, note that it's possible that multiple `execute(service:)` calls were made too. It's therefore important not to progress down to reading the `self.requestSequence` as it'd leave us in undefined double consumption state
                // Call the `earlyShutdown()` handler, just to let the app know, but the decision is unimportant, as we're exiting immediately
                _ = service.earlyShutdown()
                return

            case .secondaryExecution:
                // Straight up application error
                throw Errors.multipleServiceExecutionsUnsupported
            }
        }

        await withTaskGroup { group in
            for await request in self.requestSequence {
                switch request {
                case .request(let request):
                    group.addTask {
                        do {
                            // TODO: handle the `ObservabilityResult` here
                            _ = try await service.request(
                                input: request.input,
                                output: request.output,
                                requestContext: request.context
                            )
                            self.stateMachine.advance {
                                $0.requestHandlingCompleted(
                                    subRequestID: request.id,
                                    possibleError: nil
                                )
                            }
                        } catch {
                            // TODO: special case `RequestExecutionErrorProtocol` and `ReportableError`, extracting info from them
                            self.stateMachine.advance {
                                $0.requestHandlingCompleted(
                                    subRequestID: request.id,
                                    possibleError: error
                                )
                            }
                        }
                    }
                case .shutdownEarly:
                    let decisionBox = DecisionBox()
                    let shouldCancel = EarlyShutdownDecision.$decision.withValue(decisionBox) {
                        service.earlyShutdown()
                        return decisionBox.cancelTask.withLock { $0 }
                    }
                    if shouldCancel {
                        group.cancelAll()
                    }
                    let outstandingHandlers = self.shutdownState.withLock { shutdownState in
                        shutdownState.isShuttingDownEarly = true
                        defer {
                            shutdownState.shutdownHandlers = []
                        }
                        return shutdownState.shutdownHandlers
                    }
                    for outstandingHandler in outstandingHandlers {
                        outstandingHandler()
                    }
                }
            }
        }
    }

    /// The provided handler gets invoked when early shutdown is performed.
    public func withEarlyShutdownHandler<T>(
        _ body: () async throws -> T,
        onEarlyShutdown handler: @escaping @Sendable () -> Void
    ) async rethrows -> T {
        let isShuttingDownEarly = self.shutdownState.withLock {
            guard !$0.isShuttingDownEarly else {
                return true
            }
            $0.shutdownHandlers.append(handler)
            return false
        }

        if isShuttingDownEarly {
            handler()
        }

        return try await body()
    }

    /// This function allows to poll for whether early shutdown is requested.
    public var isShuttingDownEarly: Bool {
        self.shutdownState.withLock {
            $0.isShuttingDownEarly
        }
    }
}

/// A means to provide additional context in the event of certain classes of failure
/// These might result in SRE or routing layer action for the node, for example if a class of errors
/// indicated a possible hardware fault, but it not intended to control the flow of the request
public enum ObservabilityResult {
    /// The request should be considered a complete success.
    case success
    /// A failure of some kind occured within the cloud app such that this request is not a success.
    /// The CloudApp has dealt with informing the calling client via the ``ResponseWriter``,
    /// and this is simply to provide observability to the Data Plane and routing Plane about that.
    case controlledError(any RequestExecutionErrorProtocol)
}

/// Any Error confirming to this thrown from ``CloudAppService.request`` will
/// result in the equivalent ``ObservabilityResult`` also being provided to the routing layer.
public protocol RequestExecutionErrorProtocol: Error {
    /// A short human readable description of the error code
    var errorMessage: StaticString { get }
    /// An application owned indication of the sort of error.
    /// By being limited to a UInt32 we prevent information egress and this then allows
    /// a simple way to sending "useful in aggregate" context for followup checks.
    /// There is no need for CloudApp adopters to worry about collisions with other adopters,
    /// these error codes are provided in context of the Cloudapp in downstream observability systems
    var errorCode: UInt32 { get }
}

public struct RequestExecutionError: RequestExecutionErrorProtocol {
    public let errorMessage: StaticString
    public let errorCode: UInt32

    init(errorMessage: StaticString, errorCode: UInt32) {
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

extension RequestExecutionError: ReportableError {
    package var publicDescription: String {
        "RequestExecutionError(errorCode: \(self.errorCode), errorMessage: \(self.errorMessage))"
    }
}

public protocol CloudAppService: Sendable {
    /// Request handling completes when `request` exits.
    ///
    /// Due to the multi layered nature of the protocol within PCC (this only covers some sapects):
    /// 1. outer unencrypted layer visible to the gateway which includes:
    /// 2. PCC encrypted layer visible to (parts of) CloudBoard which includes:
    /// 3. Application layer byte chunks (opaque to CloudBoard)
    /// ...the return/error handling is somewhat unconventional.
    ///
    /// This is due to the need for the encryption protected stream to be the source of truth to the client, but where possible
    /// we do not wish to entirely hide from the rest of the system that failures have occured.
    ///
    /// The possible outcomes of the request are:
    /// 1. Complete Success
    ///    * return ``ObservabilityResult.success``
    /// 2. Controlled Failure: The CloudApp is entirely capable of handling themselves:
    ///    * Example: a request input was too large/malformed/not supported
    ///    * return ``ObservabilityResult.controlledError``
    /// 3. Uncontrolled Failure: Possibly unexpected, but uncontrolled failure occurs
    ///    * Example: Some unexpected Error calling out to another other part of the system which fails
    ///    * This is indicated by throwing an error from ``request``
    /// 4. Panic (e,g, fatalError or precondition checks)
    ///    * CloudApps MUST not call exit, but traps of other forms are inevitable
    ///
    /// 1 is simple - no errors.
    /// 4 is treated by upstream components of the data plane as an Uncontrolled Failure.
    ///   * No cleanup within the CloudApp is possible so any Adopters which are relying on that cleanup phase
    ///   need to account for this perhaps not happening in the event of a panic.
    ///
    /// The distinction between 2 and 3 is worth understanding.
    ///
    /// Controlled Failure
    /// This is communicated back to the client on the application layer of the PCC protocol, this means that is provided back
    /// to the adopter code on the callee side in full.
    /// The PCC platform does not treat the request as being a "failure", but will update observability/logging to allow these to
    /// be tracked.
    /// The publically disclosable details of the error are provided to the Gateway (ROPES) for informational purposes
    ///    * In aggregate it decide to take action against a compute node which is experiencing many such errors
    ///    * Takes no action w.r.t. the request it would not do in the event of a complete success
    ///
    /// Uncontrolled Failure
    /// There is no need for CloudApp implementers to implement "Gotta catch Them all" error handling, and convert them all to
    /// ControlledFailures unless they would get value from this. The PCC protocol allows for communicating a request failure
    /// to the client (for example pccd, if initiated from a device) in a general fashion which will end up in standard logs and
    /// metrics automatically. In addition many unexpected errors might implement mechanisams such as ``ReportableError``
    /// where additional publicly visible information can be logged usefully by code that understands the idioms.
    /// Doing that correctly is non trivial (and may evolve), there is no need for each adopter to take on that responsibility.
    ///
    /// In the case of Controlled Failures adopter specific privacy preserving information is presented for use by the routing
    /// systems. To make it simple for that to happen in the uncontrolled case as well (where possible) any Error which implements
    /// ``RequestExecutionErrorProtocol`` thrown from this function will result in the information it exposes being reported to
    /// the Gateway in addition to being treated as a failure at the PCC level.
    ///
    /// `InputData` & `ResponseWriter` handle messages while `RequestContext` provides request specific contextual data.
    func request(
        input: InputData,
        output: ResponseWriter,
        requestContext: RequestContext
    ) async throws -> ObservabilityResult

    /// This function delivers early shutdown notification.
    ///
    /// The default implementation of `earlyShutdown` cancels the outstanding `Task` executing  `request(input:output:requestContext:)`.
    /// That default implementation can be overridden. At that point number of different APIs exist to observe the early shutdown, including:
    /// * `CloudAppProcess.withEarlyShutdownHandler`
    /// * `CloudAppProcess.isShuttingDownEarly`
    func earlyShutdown()
}

extension CloudAppService {
    public func earlyShutdown() {
        EarlyShutdownDecision.decision.cancelTask.withLock {
            $0 = true
        }
    }
}

public struct InputData: AsyncSequence, Sendable {
    private let inputDataProducer: AsyncThrowingStream<Data, any Error>
    private let inputDataConsumer: AsyncThrowingStream<Data, any Error>.Continuation

    init() {
        let (producer, consumer) = AsyncThrowingStream<Data, any Error>.makeStream()
        self.inputDataProducer = producer
        self.inputDataConsumer = consumer
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncThrowingStream<Data, any Error>.AsyncIterator

        public mutating func next() async throws -> Data? {
            try await self.iterator.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: self.inputDataProducer.makeAsyncIterator())
    }

    package func yield(_ data: Data) {
        self.inputDataConsumer.yield(data)
    }

    package func finish(throwing possibleError: (any Error)?) {
        self.inputDataConsumer.finish(throwing: possibleError)
    }
}

public final class ResponseWriter: Sendable {
    private let subRequestID: CloudAppSubRequestID
    private let stateMachine: CloudAppStateMachine

    init(
        subRequestID: CloudAppSubRequestID,
        stateMachine: CloudAppStateMachine
    ) {
        self.subRequestID = subRequestID
        self.stateMachine = stateMachine
    }

    /// Write the response out. With the writeout taking longer in case of backpressure.
    public func write(_ output: Data) async throws {
        // NOTE: we don't actually backpressure in this implementation, but we could propagate the gRPC backpressure if this becomes an issue
        self.stateMachine.advance {
            $0.requestOutputGenerated(subRequestID: self.subRequestID, outputData: output)
        }
    }
}

public struct NodeResourceID: Sendable, CustomStringConvertible {
    public let rawValue: Int64

    public init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }

    public var description: String {
        self.rawValue < 0 ? "unavailable" : String(self.rawValue)
    }
}

public struct WarmupContext: Sendable {
    public let nodeResourceID: NodeResourceID

    public init(nodeResourceID: NodeResourceID) {
        self.nodeResourceID = nodeResourceID
    }
}

public struct TraceContext: Sendable, Hashable {
    public var traceIDMostSigBits: UInt64
    public var traceIDLeastSigBits: UInt64
    public var spanID: UInt64
    public var parentSpanID: UInt64?

    public init(traceIDMostSigBits: UInt64, traceIDLeastSigBits: UInt64, spanID: UInt64, parentSpanID: UInt64? = nil) {
        self.traceIDMostSigBits = traceIDMostSigBits
        self.traceIDLeastSigBits = traceIDLeastSigBits
        self.spanID = spanID
        self.parentSpanID = parentSpanID
    }
}

/// Adopter-provided key material forwarded alongside the request.
public struct OpaqueCryptoMaterial: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Adopter-provided identifier for the material.
    public var id: String
    public var material: Data

    public init(id: String, material: Data) {
        self.id = id
        self.material = material
    }

    /// Redacts the raw key material to avoid leaking it via logging, string interpolation,
    /// or error/crash dumps; only the identifier and byte count are exposed.
    public var description: String {
        "OpaqueCryptoMaterial(id: \(self.id), material: \(self.material.count) bytes)"
    }

    public var debugDescription: String {
        self.description
    }
}

public struct ConnectionContext: Sendable, Hashable {
    public var requestID: String
    public var bundleID: String
    public var bundleVersion: String
    public var featureID: String
    public var clientInfo: String
    public var workloadType: String
    public var workloadParameters: [String: [String]]
    public var automatedDeviceGroup: String
    public var traceContext: TraceContext?

    public init(
        requestID: String,
        bundleID: String,
        bundleVersion: String,
        featureID: String,
        clientInfo: String,
        workloadType: String,
        workloadParameters: [String: [String]],
        automatedDeviceGroup: String,
        traceContext: TraceContext? = nil
    ) {
        self.requestID = requestID
        self.bundleID = bundleID
        self.bundleVersion = bundleVersion
        self.featureID = featureID
        self.clientInfo = clientInfo
        self.workloadType = workloadType
        self.workloadParameters = workloadParameters
        self.automatedDeviceGroup = automatedDeviceGroup
        self.traceContext = traceContext
    }
}

public struct RequestContext: Sendable {
    public let connectionContext: ConnectionContext
    /// Adopter-provided key material forwarded with the sub-request (empty unless the
    /// request carried crypto material).
    public let opaqueCryptoMaterial: [OpaqueCryptoMaterial]
    /// Derives subordinate keys from the request DEK held by `cb_jobhelper`.
    public let keyDeriver: any KeyDeriving
}
