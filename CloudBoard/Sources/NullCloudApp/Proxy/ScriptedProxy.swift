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

import CloudBoardCommon
import Synchronization
internal import CloudBoardDomain
import CloudBoardJob
import CloudBoardLogging
import Foundation
import os

/// Provides a mode to perform multiple requests indicating reuse
/// this code is very similar to the ReuseTests
/// Note, this uses the convention "invoke" to mean a call to ``PCCClient/makePCCRequest``
final class ScriptedProxy: NullAppRole {
    static var serviceName: NullAppServiceName { .proxyScriptApp }

    fileprivate static let reuseSentinelKey = "nullproxy.reuse"
    fileprivate static let reuseSentinelWorkload = [reuseSentinelKey: ["true"]]
    /// used if no input provided
    static let defaultComputeInput = Input(
        responseTokenCount: 1,
        responseTokenSize: 1,
        timeToFirstTokenMilliseconds: 1,
        timeBetweenSubsequentTokensMilliseconds: 1,
        crashBeforeFirstResponseToken: false,
        crashOnResponseToken: nil,
        crashWithFatalError: false,
    )

    /// Allow expression of what reuse (if any) to apply on each invoke
    enum ReuseInputs: Encodable {
        /// Do not specify any reuse at all (the default)
        case noReuse
        /// Feeds into the resulting ``CloudBoardJobCore/ReuseTarget`` but lets the script talk in terms of
        /// the result of previous named (``ScriptedProxy/PCCRequestDetails/name``) invoke call
        case reuse(
            /// The EnsembleInstanceId that was used for the named target used
            target: String,
            /// If true the rack reported by the named target is used
            targetRack: Bool,
            /// These are simply directly inserted.
            /// The default is a sentinel value that lets ROPES view of the practicality of reuse
            /// for each invoke be logged
            additionalWorkload: [String: [String]] = ScriptedProxy.reuseSentinelWorkload
        )
    }

    /// Whether to wait for the invoke or not
    enum Lifecycle: Encodable {
        /// Wait on the invoke till it finishes
        case waitForCompletion
        /// Carry on with the script, leave the invoke running in an unstructured task.
        /// `waitAtEnd` controls whether the entire request will wait for it at the end or not.
        /// For an invoke using response bypass, where you want the proxy to exit once the invoke is set up,
        /// this should be false.
        /// `control` allows for linking the lifetime of the invoke to some trigger.
        /// This requires background else the script will just deadlock
        case background(waitAtEnd: Bool = true, control: Control = .freeRun)
    }

    /// What to do with the spawned invoke in relation to other ones.
    /// This is _best effort_ and normally requires the controlled request is operating in "echo" mode
    /// to funtion correctly.
    /// Remember timeouts within ROPES/CloudBoard may terminate the request if things take too long
    enum Control: Encodable {
        /// The invoke is ran as fast as possible
        case freeRun
        /// Attempt to hold the invoke open till the specific trigger
        case holdTill(trigger: String)
    }

    /// what to send to the compute ensemble
    enum InputSource: Encodable {
        /// Pass only the input in the first chunk
        case firstInputChunkToSelf
        /// send the provided chunks one after the other
        case explicit([String])
    }

    /// Expression of how to perform a ``PCCClient/makePCCRequest``
    struct PCCRequestDetails: Encodable {
        var reuse: ReuseInputs
        var lifecycle: Lifecycle = .waitForCompletion
        var inputSource: InputSource = .firstInputChunkToSelf
        /// allows explicit selection of the role the compute node should fulfill
        var computeRole: String? = nil
        /// A reference that allows the pcc ensemble used for the request to
        /// be the target of future requests for reuse purposes
        var name: String? = nil
    }

    /// Represents the actions which can happen in a script.
    /// Each "line" in the script gets one event
    enum ScriptEvent: Encodable {
        /// A single ``PCCClient/makePCCRequest``
        case makePCCRequest(PCCRequestDetails)
        /// Trigger the `name` anything waiting on that will continue
        case trigger(name: String)
        /// Inserted as the final entry atuomatically
        /// Do not add it to your scripts
        case complete
    }

    /// a line in the script, synthesized from the list of events
    fileprivate struct ScriptLine: Encodable {
        /// An index in the script, but starting from 1 (human centric)
        var lineNum: Int
        /// The event this line requires
        var event: ScriptEvent
        /// true IFF this line contains the last request.
        /// For a repeat this would imply the repeat count is > 0
        var isLastRequest: Bool = false
    }

    /// A script example that exercises reuse flows
    private static let reuseTillOverflow: [ScriptEvent] = [
        [
            // establish the target for later reuse
            ScriptEvent.makePCCRequest(
                .init(reuse: .noReuse, lifecycle: .waitForCompletion, name: "target")
            ),
        ],
        // fill the target node up
        [ScriptEvent](
            repeating:
            ScriptEvent.makePCCRequest(
                .init(
                    reuse: .reuse(target: "target", targetRack: false),
                    lifecycle: Lifecycle.background(control: .holdTill(trigger: "release")),
                    // echo lets us hold the request open (to a degree)
                    computeRole: "echo"
                )
            ),
            // The count has to agree with the limit set on the node
            // The low number here is deliberate to reduce the time the script takes,
            // When using this script the follwoing settings should be overrriden in secure-config to
            // trigger the intended flow:
            // "com.apple.cloudboard.cloudApp.NullCloudApp.prewarmPoolSize": 2
            // "com.apple.cloudboard.cloudApp.NullCloudApp.maxProcessCount": 2
            count: 2
        ),
        [
            // Send another request that should need to use a different ensemble
            // due to the above holding jobs
            ScriptEvent.makePCCRequest(
                .init(
                    reuse: .reuse(target: "target", targetRack: false),
                    lifecycle: .waitForCompletion
                )
            ),
            // release the held jobs to stop timeouts
            ScriptEvent.trigger(name: "release"),
        ],
    ].flatMap { $0 }

    /// What will happen by default
    /// For development testing this can be edited, or several different scripts can be defined
    /// and controlled from workload parameters
    private static let defaultScript: [ScriptEvent] = reuseTillOverflow

    private let log: Logger
    private let semantics: PCCRequestSemantics
    private let script: [ScriptLine]
    private let namedWorkers = Mutex<[String: PCCWorkerInfo]>([:])
    private let _triggers = Mutex<[String: Promise<Void, CancellationError>]>([:])

    init(
        log: Logger,
        semantics: PCCRequestSemantics,
        script: [ScriptEvent] = defaultScript
    ) {
        self.log = log
        self.semantics = semantics
        var lineIndex = 0
        var lastRequestIndex = -1
        var script = script.map {
            defer {
                lineIndex += 1
            }
            switch $0 {
            case .makePCCRequest:
                lastRequestIndex = lineIndex
            default:
                ()
            }
            return ScriptLine(lineNum: lineIndex + 1, event: $0)
        }
        if lastRequestIndex >= 0 {
            script[lastRequestIndex] = ScriptLine(
                lineNum: script[lastRequestIndex].lineNum,
                event: script[lastRequestIndex].event,
                isLastRequest: true
            )
        }
        self.script = script
    }

    private func waitForTrigger(name: String) async throws {
        let future = self._triggers.withLock { triggers in
            var promise = triggers[name]
            if promise == nil {
                promise = Promise<Void, CancellationError>(autoFailureIfUnfulfilled: CancellationError())
                triggers[name] = promise
            }
            return Future(promise!)
        }
        try await future.value
    }

    private func trigger(name: String) {
        self._triggers.withLock { triggers in
            if let promise = triggers[name] {
                promise.succeed()
            } else {
                let promise = Promise<Void, CancellationError>()
                triggers[name] = promise
                promise.succeed()
            }
        }
    }

    fileprivate enum JsonEventOutput: Encodable {
        case script(ScriptLine)
        case forwardedChunk(lineNum: Int, output: String)
        case forwardedError(lineNum: Int, detailedError: String)
        case forwardedSummary(lineNum: Int, status: PCCClient.PCCWorkerResponse.Result.Status)
    }

    func run(
        input: CloudBoardJobCore.InputData,
        responder: CloudBoardJobCore.ResponseWriter,
        environment: CloudBoardJobCore.CloudAppEnvironment,
        spanID: UInt64
    ) async throws {
        let requestID = environment.plaintextMetadata.requestID
        // parse the input like TestApp
        self.log.log("""
        request.uuid=\(requestID, privacy: .public)
        message=Proxy operating in hardcoded scripted multi group mode - reading input
        """)
        // don't take action on any parameters, just forward what we get to each compute node
        var firstInputChunk: Data? = nil
        for try await data in input {
            if firstInputChunk == nil {
                firstInputChunk = data
            }
            self.log.log("""
            request.uuid=\(requestID, privacy: .public)
            message=received input
            """)
        }
        self.log.log("""
        request.uuid=\(requestID, privacy: .public)
        message=input completed - running script
        """)

        // consuming tools mostly assume the output from the null app is json
        // no need to expend effort on much pretty printing, that can be done on the client as needed
        try await responder.write("{\n\"events\": [\n".data)
        // all outputs now must be complete json objects representing JsonEventOutput followed by ","
        var waitForFinishAtEnd: [SingleScriptEventRunner] = []
        for line in self.script {
            // all outputs now must be complete json objects representing JsonEventOutput followed by ","
            try await responder.writeScriptLine(line)
            switch line.event {
            case .makePCCRequest(let invoke):
                let runner = SingleScriptEventRunner(
                    parent: self,
                    environment: environment,
                    invoke: invoke,
                    lineNum: line.lineNum,
                    isLast: line.isLastRequest,
                    spanID: spanID
                )
                try await runner.startMakePCCRequest(
                    responder: responder,
                    firstInputChunk: firstInputChunk
                )
                switch invoke.lifecycle {
                case .background(let waitAtEnd, control: _):
                    if waitAtEnd {
                        waitForFinishAtEnd.append(runner)
                    } else {
                        runner.log(publicMessage: "letting invoke run independent of this request")
                    }
                case .waitForCompletion:
                    await runner.waitForCompletion(responder: responder)
                }
            case .trigger(name: let name):
                self.trigger(name: name)
            case .complete:
                fatalError("scripts should not contain the complete - inserted automatically")
            }
        }
        // now wait for all the backgrounded tasks that were not fire and forget
        for runner in waitForFinishAtEnd {
            await runner.waitForCompletion(responder: responder)
        }
        // this line makes a legal JSON array
        try await responder.writeScriptLine(
            .init(
                lineNum: self.script.last.map { $0.lineNum + 1 } ?? 1,
                event: .complete
            ),
            includeTrailingComma: false
        )
        try await responder.write("\n]\n}".data)
        try responder.finish()
    }

    private final class SingleScriptEventRunner: Sendable {
        let parent: ScriptedProxy
        let requestID: String
        let lineNum: Int
        let environment: CloudAppEnvironment
        let invoke: PCCRequestDetails
        let responseBypass: Bool
        let reuseTarget: ReuseTarget?
        let spanID: UInt64
        let isLast: Bool
        let finishedPromise = Mutex<Promise<(any Error)?, CancellationError>?>(nil)

        internal init(
            parent: ScriptedProxy,
            environment: CloudAppEnvironment,
            invoke: ScriptedProxy.PCCRequestDetails,
            lineNum: Int,
            isLast: Bool,
            spanID: UInt64
        ) {
            self.parent = parent
            self.requestID = environment.plaintextMetadata.requestID
            self.lineNum = lineNum
            self.isLast = isLast
            self.environment = environment
            self.invoke = invoke
            self.spanID = spanID
            // Response bypass kicks in only on the final request, and only if configured to do so
            self.responseBypass = (parent.semantics.responseBypass ?? false) && isLast
            switch invoke.reuse {
            case .noReuse:
                self.reuseTarget = nil
            case .reuse(let target, let includeRack, let additionalWorkload):
                guard let targetWorkerInfo = self.parent.namedWorkers.withLock({ $0[target] }) else {
                    fatalError("script tried to use reuse \(target) but no such entry!")
                }
                self.reuseTarget = ReuseTarget(
                    ensemble: targetWorkerInfo.ensemble,
                    rack: includeRack ? targetWorkerInfo.rack : nil,
                    workloadAdditions: additionalWorkload
                )
            }
        }

        fileprivate func log(publicMessage: String) {
            self.parent.log.info(
                """
                request.uuid=\(self.requestID, privacy: .public)
                script.lineNumber=\(self.lineNum)
                script.name=\(self.invoke.name ?? "")
                reuse.requested=\(self.reuseTarget != nil)
                message=\(publicMessage, privacy: .public)
                """
            )
        }

        private func getSendChunks(firstInputChunk: Data?) throws -> [Data] {
            switch self.invoke.inputSource {
            case .firstInputChunkToSelf:
                guard let firstInputChunk else {
                    if self.environment.requestBypassed {
                        // doing this is fairly arbitrary - it can be changed without significant impact
                        self.parent.log.log("""
                        request.uuid=\(self.requestID, privacy: .public)
                        message=request bypass using defaults for compute - running script
                        """)
                        let testAppInput = ScriptedProxy.defaultComputeInput
                        return try [JSONEncoder().encode(testAppInput)]
                    }
                    fatalError(
                        "script line \(self.lineNum) requested firstInputChunkToSelf but no input chunk has been received. A placeholder is only inserted for request bypass"
                    )
                }
                return [firstInputChunk]
            case .explicit(let chunks):
                return chunks.map { $0.data }
            }
        }

        /// Returns once the request has been confirmed to have started
        func startMakePCCRequest(
            responder: ResponseWriter,
            firstInputChunk: Data?
        ) async throws {
            let finished = self.finishedPromise.withLock {
                guard $0 == nil else {
                    fatalError("called executeMakePCCRequest on already run/running instance")
                }
                $0 = Promise<(any Error)?, CancellationError>(autoFailureIfUnfulfilled: CancellationError())
                return $0!
            }
            let sendToCompute = try getSendChunks(firstInputChunk: firstInputChunk)
            var routingParameters = self.parent.semantics.parameters
            if let computeRoleOverride = self.invoke.computeRole {
                routingParameters[NullCloudApp.workloadComputeModeKey.description] = [computeRoleOverride]
            }
            let started = Promise<Void, CancellationError>()
            // This task can *never* throw (only cause a fatal so it's safe to just start it and forget
            // about it. The promise is completed on all code paths
            Task {
                do {
                    try await self.environment.pccClient.makePCCRequest(
                        serviceName: self.parent.semantics.serviceName,
                        routingParameters: routingParameters,
                        effort: ExpectedEffort(namedEfforts: ["input-processing": 0.8]),
                        reuseTarget: self.reuseTarget,
                        responseBypass: self.responseBypass,
                        isFinal: self.isLast,
                        spanID: self.spanID
                    ) { handler in
                        started.succeed()
                        try await self.handleProxyInvoke(
                            handler,
                            responder: responder,
                            sendToCompute: sendToCompute
                        )
                    }
                    finished.succeed(with: nil)
                } catch {
                    // carry on regardless of success or failure
                    self.parent.log.error(
                        """
                        request.uuid=\(self.requestID, privacy: .public)
                        script.lineNumber=\(self.lineNum)
                        script.name=\(self.invoke.name ?? "")
                        reuse.requested=\(self.reuseTarget != nil)
                        error=\(String(unredacted: error), privacy: .public)
                        """
                    )
                    // we can give the client the error in full
                    // if this fails we should just die
                    try! await responder.writeJsonOutputEvent(.forwardedError(
                        lineNum: self.lineNum,
                        detailedError: error.localizedDescription
                    ))
                    finished.succeed(with: error)
                }
            }
            self.log(publicMessage: "waiting for invoke to start")
            try await Future(started).value
            self.log(publicMessage: "started")
        }

        fileprivate func handleProxyInvoke(
            _ handler: PCCClient.PCCRequestSession,
            responder: ResponseWriter,
            sendToCompute: [Data]
        ) async throws {
            func log(publicMessage: String) {
                self.parent.log.info(
                    """
                    request.uuid=\(self.requestID, privacy: .public)
                    workerSession.uuid=\(handler.sessionID, privacy: .public)
                    script.lineNumber=\(self.lineNum)
                    script.name=\(self.invoke.name ?? "")
                    reuse.requested=\(self.reuseTarget != nil)
                    reuse.viable=\(
                        handler.workerInfo.workload[ScriptedProxy.reuseSentinelKey] ?? ["false"],
                        privacy: .public
                    )
                    message=\(publicMessage, privacy: .public)
                    """
                )
            }
            log(publicMessage: "request running on \(handler.workerInfo)")
            if let name = self.invoke.name {
                self.parent.namedWorkers.withLock {
                    $0[name] = handler.workerInfo
                }
            }
            for data in sendToCompute {
                try await handler.requestWriter.write(data)
            }
            log(publicMessage: "sent input")
            switch self.invoke.lifecycle {
            case .background(waitAtEnd: _, control: .holdTill(let trigger)):
                log(publicMessage: "waiting for trigger \(trigger)")
                try await self.parent.waitForTrigger(name: trigger)
                log(publicMessage: "proceeding post trigger \(trigger)")
            default:
                () // nothing to do
            }
            log(publicMessage: "finishing output then waiting for result")
            try await handler.requestWriter.finish()
            for try await response in handler.responseStream {
                try await self.forward(responder: responder, lineNum: self.lineNum, response)
            }
            log(publicMessage: "output complete")
        }

        fileprivate func forward(
            responder: ResponseWriter,
            lineNum: Int,
            _ response: PCCClient.PCCRequestSession.ResponseData.Element
        ) async throws {
            switch response {
            case .payload(let data):
                try await responder.writeJsonOutputEvent(.forwardedChunk(
                    lineNum: lineNum, output: data.utf8StringOrBase64
                ))
            case .result(let summary):
                // carry on regardless of success or failure
                try await responder.writeJsonOutputEvent(.forwardedSummary(
                    lineNum: lineNum, status: summary.status
                ))
            }
        }

        /// Wait for the invoke to finish, must only be called after ``startMakePCCRequest`` returns
        func waitForCompletion(responder: ResponseWriter) async {
            let finished = self.finishedPromise.withLock {
                guard let promise = $0 else {
                    fatalError("called waitForInvokeToFinish on instance not yet started")
                }
                return promise
            }
            do {
                self.log(publicMessage: "waiting for pcc request to complete")
                if let error = try await Future(finished).value {
                    self.log(publicMessage: "makePCCRequest completed with error \(String(unredacted: error))")
                    try await responder.writeFullErrorDetails(lineNum: self.lineNum, error: error)
                } else {
                    self.log(publicMessage: "makePCCRequest completed without error")
                }
            } catch {
                // if we can't report an error about an error lets just fail fast
                try! await responder.writeFullErrorDetails(lineNum: self.lineNum, error: error)
            }
        }
    }
}

extension Data {
    /// Converts Data to a UTF-8 encoded String.
    private var utf8String: String? {
        String(data: self, encoding: .utf8)
    }

    /// Converts Data to a String by trying utf8, and if not base64 encoding.
    fileprivate var utf8StringOrBase64: String {
        guard let s = utf8String else {
            return self.base64EncodedString()
        }
        return s
    }
}

extension String {
    /// Converts the string to Data using UTF-8 encoding
    fileprivate var data: Data {
        return Data(self.utf8)
    }
}

// Emit snippets that form entries in a json array - with a trailing ",\n"
extension ResponseWriter {
    fileprivate func writeJsonOutputEvent(
        _ event: ScriptedProxy.JsonEventOutput,
        includeTrailingComma: Bool = true
    ) async throws {
        var data = try JSONEncoder().encode(event)
        if includeTrailingComma {
            data.append(",\n".data)
        }
        try await self.write(data)
    }

    fileprivate func writeScriptLine(
        _ line: ScriptedProxy.ScriptLine,
        includeTrailingComma _: Bool = true
    ) async throws {
        try await self.writeJsonOutputEvent(.script(line))
    }

    // we can give the client the error in full
    fileprivate func writeFullErrorDetails(lineNum: Int, error: any Error) async throws {
        try await self.writeJsonOutputEvent(.forwardedError(
            lineNum: lineNum,
            detailedError: error.localizedDescription
        ))
    }
}
