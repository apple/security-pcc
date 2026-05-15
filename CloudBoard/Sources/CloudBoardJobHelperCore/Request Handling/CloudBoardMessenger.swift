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

import CloudBoardAttestationDAPI
import CloudBoardCommon
import CloudBoardDomain
import CloudBoardJobAPI
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CloudBoardMetrics
@_spi(SEP_Curve25519) import CryptoKit
@_spi(SEP_Curve25519) import CryptoKitPrivate
import Foundation
internal import ObliviousX
import CloudBoardDomain
import LocalAuthentication
import os

internal let cbSignposter = OSSignposter(subsystem: "com.apple.cloudos.cloudboard", category: "cb_jobhelper")

/// Messenger responsible for communication with cloudboardd, forms the stateful core functionality of a jobhelper
/// instance with respect to the needed encryption on the inbound and outboud streams.
/// This type is *not* responsible for logic and state concerning the PCC protocol (the protobuf messages the client
/// understands) nor
/// the message layer between the jobhelper and the cloud app itself.
actor CloudBoardMessenger: CloudBoardJobHelperAPIClientToServerProtocol {
    public static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CloudBoardMessenger"
    )

    public static let tracingLogger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard.tracing",
        category: "CloudBoardMessenger"
    )

    enum CloudBoardMessengerError: ReportableError {
        case runNeverCalled
        case warmupNeverCalled
        case warmupCalledTwice
        case supportAppsUninitialized

        var publicDescription: String {
            switch self {
            case .runNeverCalled: "runNeverCalled"
            case .warmupNeverCalled: "warmupNeverCalled"
            case .warmupCalledTwice: "warmupCalledTwice"
            case .supportAppsUninitialized: "supportAppsUninitialized"
            }
        }
    }

    /// The metrics system to use.
    private let metrics: MetricsSystem
    private let laContextProvider: LocalAuthContextProvider
    private var ohttpKeyStateMachine = OHttpKeyStateMachine()

    // Why the job helper has been instantiated
    let hostType: JobHelperHostType
    let attestationClient: CloudBoardAttestationAttestationLookupProtocol

    // This responds back to cloudboard as a means to send the response information
    // (i.e. data to send to the parent or direct to the client).
    let server: CloudBoardJobHelperAPIServerToClientProtocol

    let workloadProvider: CloudBoardJobHelperWorkloadProvider
    let workloadPromise: Promise<(ManagedCloudAppProtocol, [ManagedSupportAppProtocol], [AssetMetadata]), Error>
    let ensembleKeyDistributor: EnsembleKeyDistributorProtocol
    let pirHelper: PIRHelperProtocol

    var nodeAppData: [String: Data] = [:]

    // Holds request-specific secrets (Data Encryption Key) and provides functionality to operate on it.
    // CloudBoardMessenger uses this to provide the Data Encryption Key to other parts of CloudBoardJobHelper that need
    // access to the DEK.
    let requestSecrets: RequestSecrets

    // once the request stream is decrypted the raw bytes should be passed on via this continuation
    let encodedRequestContinuation: AsyncStream<PipelinePayload>.Continuation

    // This is the response data from the cloud app
    let responseStream: AsyncStream<WorkloadJobManager.OutboundMessage>

    // This state machine *always* covers the input (from cloudboardd)
    // This is true whether or not "Request Bypass" is active because cloudboardd
    // mediates getting the data to here correctly, and the unwrapping of the DEK
    // *requires* that a SEP backed key for this node is used.
    var parentOhttpStateMachine = OHTTPServerStateMachine()

    // The encapsulator will be setup once the relevant OhttpStateMachine is ready to use
    // if responseBypass is required then this may not actually go to the parent
    var responseEncapsulator: StreamingResponseProtocol?

    // Not known till the Parameters message
    // This being nillable is not as risky as it might seem because most code simply can't happen till the
    // decryption has happened - which is not possible till the parameters message is received
    private var requestParameters: Parameters?
    private var abandoned: Bool = false
    private let jobUUID: UUID
    private let spanID: UInt64
    private var warmupReceived: Bool = false
    private var supportAppNames: [String]? = nil
    private let shadowConfigLookup: @Sendable (String) throws -> SecureConfig.ShadowCloudAppConfig

    init(
        hostType: JobHelperHostType,
        attestationClient: CloudBoardAttestationAttestationLookupProtocol,
        server: CloudBoardJobHelperAPIServerToClientProtocol,
        workloadProvider: CloudBoardJobHelperWorkloadProvider,
        workloadPromise: Promise<(ManagedCloudAppProtocol, [ManagedSupportAppProtocol], [AssetMetadata]), Error>,
        ensembleKeyDistributor: EnsembleKeyDistributorProtocol,
        pirHelper: PIRHelperProtocol,
        requestSecrets: RequestSecrets,
        encodedRequestContinuation: AsyncStream<PipelinePayload>.Continuation,
        responseStream: AsyncStream<WorkloadJobManager.OutboundMessage>,
        metrics: MetricsSystem,
        jobUUID: UUID,
        jobHelperSpanID: UInt64,
        laContextProvider: LocalAuthContextProvider,
        shadowConfigLookup: @escaping @Sendable (String) throws -> SecureConfig.ShadowCloudAppConfig
    ) {
        self.hostType = hostType
        self.attestationClient = attestationClient
        self.server = server
        self.workloadProvider = workloadProvider
        self.workloadPromise = workloadPromise
        self.ensembleKeyDistributor = ensembleKeyDistributor
        self.pirHelper = pirHelper
        self.requestSecrets = requestSecrets
        self.encodedRequestContinuation = encodedRequestContinuation
        self.responseStream = responseStream
        self.metrics = metrics
        self.jobUUID = jobUUID
        self.spanID = jobHelperSpanID
        self.laContextProvider = laContextProvider
        self.shadowConfigLookup = shadowConfigLookup
    }

    func warmup(_ info: WarmupInfo) async throws {
        do {
            guard !self.warmupReceived else {
                throw CloudBoardMessengerError.warmupCalledTwice
            }
            CloudBoardMessengerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received warmup data"
            ).log(to: Self.tracingLogger, level: .default)
            self.warmupReceived = true
            let cloudAppNameToLaunch: String
            let shadow = try self.shadowConfigLookup(info.cloudAppName)
            if shadow.enabled, shadow.remoteCloudApps {
                CloudBoardMessengerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "ShadowTunnelCloudApp replacing the real one"
                ).log(to: Self.tracingLogger, level: .default)
                cloudAppNameToLaunch = "ShadowTunnelCloudApp"
            } else {
                cloudAppNameToLaunch = info.cloudAppName
            }
            let workload = try self.workloadProvider.getCloudApp(
                cloudAppName: cloudAppNameToLaunch,
                requestSecrets: self.requestSecrets,
                ensembleKeyDistributor: self.ensembleKeyDistributor,
                pirHelper: self.pirHelper,
                jobUUID: self.jobUUID,
                cbJobHelperLogMetadata: self.logMetadata(spanID: self.spanID)
            )

            if info.assignLAContext {
                try self.ohttpKeyStateMachine.initialiseLAContext(laContext: self.laContextProvider.getContext())
            }

            // Determine associated support apps
            self.supportAppNames = info.supportAppNames
            let supportApps = try info.supportAppNames.map { name in
                try self.workloadProvider.getSupportApp(
                    forCloudApp: info.cloudAppName,
                    name: name,
                    requestSecrets: self.requestSecrets,
                    jobUUID: self.jobUUID,
                    cbJobHelperLogMetadata: self.logMetadata(spanID: self.spanID)
                ) { [weak self] cleanTermination in
                    guard let self else { return }
                    if !cleanTermination {
                        await CloudBoardMessengerCheckpoint(
                            logMetadata: self.logMetadata(spanID: self.spanID),
                            message: "Support app terminated uncleanly. Tearing down the job."
                        ).log(to: Self.tracingLogger, level: .error)
                        await self.teardown()
                    }
                }
            }

            let pirAssetsMetadata = info.assetsMetadata[.pir] ?? []
            let cloudAppAssetsMetadata = info.assetsMetadata[.cloudApp] ?? []

            self.workloadPromise.succeed(with: (workload, supportApps, pirAssetsMetadata + cloudAppAssetsMetadata))
            // Warm up cloud app, support apps, and PIR helper
            try await withThrowingTaskGroup { group in
                let info = ManagedWarmupInfo(
                    // we report the cloudApp being operated _for_ here
                    // This enables the ShadowTunnelCloudApp to do the right things
                    cloudAppName: info.cloudAppName,
                    launchdJobInstanceUUID: self.jobUUID,
                    cloudAppAssetsMetadata: cloudAppAssetsMetadata,
                    maxApplicationLayerMessageSize: info.maxApplicationLayerMessageSize
                )
                group.addTask {
                    try await workload.warmup(info: info)
                }
                for supportApp in supportApps {
                    group.addTask {
                        try await supportApp.warmup(info: info)
                    }
                }
                group.addTask {
                    try await self.pirHelper.warmup(assetsMetadata: pirAssetsMetadata)
                }

                try await group.waitForAll()
            }
        } catch {
            CloudBoardMessengerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Failed Warmup",
                error: error
            ).log(to: Self.tracingLogger, level: .error)
            throw CloudBoardJobHelperAPIError.failedWarmUp
        }
    }

    func assignLAContext() async throws {
        CloudBoardMessengerCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            message: "Assigning LA Context"
        ).log(to: Self.tracingLogger, level: .default)

        do {
            try self.ohttpKeyStateMachine.initialiseLAContext(laContext: self.laContextProvider.getContext())
            CloudBoardMessengerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Assigned LA Context"
            ).log(to: Self.tracingLogger, level: .default)
        } catch {
            CloudBoardMessengerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Failed to assign LA Context",
                error: error
            ).log(to: Self.tracingLogger, level: .error)
            throw CloudBoardJobHelperAPIError.failedAssigningLAContext
        }
    }

    public func invokeWorkloadRequest(_ request: CloudBoardDaemonToJobHelperMessage) async throws {
        do {
            self.metrics.emit(Metrics.Messenger.TotalRequestsReceivedCounter(
                action: .increment,
                // we cannot know the requestId till the parameters message, we might be warmed up for an
                // entirely separate request than we end up actually acting for.
                // One the request is known it is never changed
                automatedDeviceGroup: !(self.requestParameters?.plaintextMetadata.automatedDeviceGroup.isEmpty ?? true),
                featureId: self.requestParameters?.plaintextMetadata.featureID,
                bundleId: self.requestParameters?.plaintextMetadata.bundleID,
                inferenceId: self.requestParameters?.plaintextMetadata
                    .workloadParameters[workloadParameterInferenceIDKey]?.first
            ))
            switch request {
            case .requestChunk(let encryptedPayload, let isFinal):
                CloudBoardMessengerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "Received request chunk"
                ).log(
                    request: .init(chunk: encryptedPayload, isFinal: isFinal),
                    to: Self.tracingLogger,
                    level: .default
                )
                // check it is reasonable to see the request at all
                switch self.hostType {
                case .nack:
                    // The nacked nodes should never be passed the request.
                    // Cloudboard Daemon should have rejected this already.
                    assertionFailure("Received the client request when operating in NACK mode")

                case .proxy:
                    // CloudBoard Daemon will have rejected this if it is not allowed
                    ()

                case .worker:
                    () // always reasonable
                }
                if let data = try self.parentOhttpStateMachine.receiveChunk(encryptedPayload, isFinal: isFinal) {
                    self.metrics.emit(Metrics.Messenger.RequestChunkReceivedSizeHistogram(
                        size: data.count,
                        automatedDeviceGroup: !(
                            self.requestParameters?.plaintextMetadata.automatedDeviceGroup
                                .isEmpty ?? true
                        ),
                        featureId: self.requestParameters?.plaintextMetadata.featureID ?? "",
                        bundleId: self.requestParameters?.plaintextMetadata.bundleID ?? "",
                        inferenceId: self.requestParameters?.plaintextMetadata
                            .workloadParameters[workloadParameterInferenceIDKey]?.first
                    ))
                    self.encodedRequestContinuation.yield(.chunk(.init(chunk: data, isFinal: isFinal)))
                }
            case .parameters(let parameters):
                let parentSpanID = parameters.traceContext.spanID
                TraceContextCache.singletonCache.setSpanID(
                    parentSpanID,
                    forKeyWithID: parameters.requestID,
                    forKeyWithSpanIdentifier: SpanIdentifier.invokeWorkload
                )
                let paramtersReceivedInstant = ContinuousClock.now
                precondition(
                    self.requestParameters == nil,
                    "It's not reasonable to receive multiple parameters messages"
                )
                self.requestParameters = parameters
                if parameters.requestedNack {
                    guard self.hostType == .proxy else {
                        fatalError("sent NACK request but am not a proxy")
                    }
                    // No need to pass along anything to the cloud app, actively harmful in fact as it might
                    // start doing real work
                    // We don't even bother passing along the onetime token, we just want to get NACK done
                    // for that we need the HPKE handshake (the only unavoidable expensese)
                } else {
                    CloudBoardMessengerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        message: "Received request parameters"
                    ).log(to: Self.tracingLogger, level: .default)
                    // We split up the parameters here into:
                    // * metadata to be processed within cb_jobhelper (one-time token)
                    // * data to be forwarded to the cloud app (see ``ParametersData``).
                    // Sending parameters (handled by cloud app) first allows it to get forwarded to the
                    // app while one-time token can be processed by cb_jobhelper in parallel.

                    // Support app names are set during warm up so will always be available at this time
                    guard let supportAppNames = self.supportAppNames else {
                        throw CloudBoardMessengerError.supportAppsUninitialized
                    }
                    self.encodedRequestContinuation.yield(.parameters(.init(
                        parameters,
                        nodeAppData: self.nodeAppData,
                        launchdJobInstanceUUID: self.jobUUID,
                        supportApps: supportAppNames
                    )))
                    self.encodedRequestContinuation.yield(.oneTimeToken(parameters.oneTimeToken))
                    // only required for validation checks in the proxy
                    if self.hostType == .proxy {
                        self.encodedRequestContinuation.yield(.parametersMetaData(
                            keyID: parameters.encryptedKey.keyID,
                            workload: parameters.plaintextMetadata.workloadParameters
                        ))
                    }
                }
                do {
                    try await self.completeHPKEHandshake(parameters: parameters)
                    self.metrics.emit(Metrics.Messenger.KeyUnwrapDuration(
                        duration: paramtersReceivedInstant.duration(to: .now),
                        error: nil,
                        automatedDeviceGroup: parameters.plaintextMetadata.automatedDeviceGroup != ""
                    ))
                    // At this point we are sure that the LAContext has been used
                    // and deallocated inside completeHPKEHandshake, hence we
                    // can indicate to cloudboardd that we have used it.
                    await self.server.sendWorkloadResponse(JobHelperToCloudBoardDaemonMessage.usedLAContext)
                    CloudBoardMessengerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        message: "LAContext marked as used"
                    ).log(to: Self.tracingLogger, level: .default)

                    // Only proxy nodes or worker nodes NOT in response bypass mode should return
                    // a REL entry with the assets metadata
                    if self.hostType == .proxy || parameters.responseBypassMode == .none {
                        self.encodedRequestContinuation.yield(.readyToSendAssetsMetadataRELEntry)
                    }
                } catch {
                    self.metrics.emit(Metrics.Messenger.KeyUnwrapDuration(
                        duration: paramtersReceivedInstant.duration(to: .now),
                        error: error,
                        automatedDeviceGroup: parameters.plaintextMetadata.automatedDeviceGroup != ""
                    ))
                    CloudBoardMessengerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        message: "HPKE handshake failed",
                        error: error
                    ).log(to: Self.tracingLogger, level: .error)
                    throw error
                }
            case .workerNegotiatePick(providedByRopes: let providedByRopes):
                self.encodedRequestContinuation.yield(.workerNegotiatePick(
                    providedByRopes: providedByRopes
                ))
            case .workerAttestation(let workerAttestationInfo, let workloadParameters):
                guard let dataEncryptionKey = self.parentOhttpStateMachine.dataEncryptionKey else {
                    // It should be impossible to ever receive a worker attestation without previously having received
                    // the DEK from the client device
                    preconditionFailure("Received worker attestation before receiving DEK")
                }

                self.encodedRequestContinuation.yield(.selectedWorker(
                    info: workerAttestationInfo,
                    dek: dataEncryptionKey,
                    workloadParameters: workloadParameters
                ))
            case .workerResponseChunk(let workerID, let chunk, isFinal: let isFinal):
                self.encodedRequestContinuation.yield(.workerResponseChunk(
                    workerID,
                    .init(chunk: chunk, isFinal: isFinal)
                ))
            case .workerResponseClose(
                let workerID,
                let grpcStatus,
                let grpcMessage,
                let ropesErrorCode,
                let ropesMessage
            ):
                self.encodedRequestContinuation.yield(.workerResponseClose(
                    workerID,
                    grpcStatus: grpcStatus,
                    grpcMessage: grpcMessage,
                    ropesErrorCode: ropesErrorCode,
                    ropesMessage: ropesMessage
                ))
            case .workerResponseEOF(let workerID):
                self.encodedRequestContinuation.yield(.workerResponseEOF(workerID))
            }
        } catch let error as ReportableJobHelperError {
            CloudBoardMessengerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "invokeWorkloadRequest error",
                error: error
            ).log(to: Self.tracingLogger, level: .error)
            await self.server.sendWorkloadResponse(.failureReport(error.reason))
            throw error.wrappedError
        } catch {
            CloudBoardMessengerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "invokeWorkloadRequest error",
                error: error
            ).log(to: Self.tracingLogger, level: .error)
            throw error
        }
    }

    // if the .log call does not include additional information this is simpler
    func makeAndLogGenericTerminalError(
        _ wrappedError: Error,
        reason: FailureReason,
        message: StaticString
    ) -> ReportableJobHelperError {
        let error = ReportableJobHelperError(
            wrappedError: wrappedError,
            reason: reason
        )
        CloudBoardMessengerCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            message: message,
            error: error
        )
        .log(to: Self.tracingLogger, level: .error)
        return error
    }

    /// This will be called once and only once to setup all key exchange handshakes needed.
    /// Any request (input) data that has been buffered will be passed to ``encodedRequestContinuation``
    /// After this call ``responseEncapsulator`` will be non nil
    private func completeHPKEHandshake(
        parameters: Parameters
    ) async throws {
        precondition(self.responseEncapsulator == nil)
        let keyID = parameters.encryptedKey.keyID
        let wrappedKey = parameters.encryptedKey.key
        let keyIDEncoded = keyID.base64EncodedString()

        let consumeKeyResult = try self.ohttpKeyStateMachine.consumeAttestedKeys()
        let ohttpKeys: [CachedAttestedKey]
        switch consumeKeyResult {
        case .available(let keys):
            ohttpKeys = keys
        case .waiting(let promise):
            CloudBoardMessengerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Waiting for OHTTP keys to become available"
            ).log(to: Self.tracingLogger, level: .default)
            ohttpKeys = try await Future(promise).valueWithCancellation
        }

        guard let ohttpKey = ohttpKeys.first(where: { $0.keyID == keyID })
        else {
            let error = ReportableJobHelperError(
                wrappedError: NodeKeyError.unknownKeyID(keyIDEncoded),
                reason: .unknownKeyID
            )
            CloudBoardMessengerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "No node key found with the provided key ID",
                error: error
            ).log(keyID: keyIDEncoded, to: Self.tracingLogger, level: .error)
            throw error
        }
        CloudBoardMessengerCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            message: "Found attested key for request"
        ).log(keyID: keyIDEncoded, to: Self.tracingLogger, level: .info)

        guard ohttpKey.expiry >= .now else {
            let error = ReportableJobHelperError(
                wrappedError: NodeKeyError.expiredKey(keyIDEncoded),
                reason: .expiredKey
            )

            CloudBoardMessengerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Provided key has expired",
                error: error
            ).log(keyID: keyIDEncoded, to: Self.tracingLogger, level: .error)

            throw error
        }

        do {
            // responseBypassMode comes from ropes, but should have been set or not by the proxy.
            // There is no attack possible there because:
            // 1. If ROPES tells a worker to perform response bypass when not actually requested:
            // - The client sees that response, which may result in an error if this response was not
            //   intended to go direct to the client, but there's no privacy attack possible there.
            // 2. If ROPES tells a worker not to perform response bypass and the proxy mandated it:
            // - The proxy will trap this and error out. Again no privacy attack
            // Therefore the compute workers just do what they are told
            // It is never legal for a proxy node to be asked to do response bypass.
            //
            // Note: this means the proxy _must_ tell ropes that response bypass is required at the point it
            // requests the node
            if parameters.responseBypassMode != .none {
                precondition(
                    self.hostType == .worker,
                    "responseBypass was requested for a \(self.hostType) node"
                )
            }

            // Ensure down stream components have information needed to function as needed for
            // the cloudApp if/when it uses proxy fucntionality.
            // We deliberately consider the proxy 'ready to go' now is to get that happening
            // in parallel while the DEK is unwrappped on the SEP
            // This means we might fail later if the DEK is bad in some way, but the latency benefit is worth it
            // If we only need to nack the proxy functionality does not require anything does not need to ready
            // anything
            if self.hostType == .proxy, !parameters.requestedNack {
                self.encodedRequestContinuation.yield(.parametersMetaData(
                    keyID: ohttpKey.attestedKey.keyID,
                    workload: parameters.plaintextMetadata.workloadParameters
                ))
            }

            // While we wait on AKS operations to complete, cloudboard’s “CPU Control Effort” decays as it appears as
            // not doing anything. We can mitigate that by spinning in the background while waiting for the operation
            // to complete.
            let completedHandshake = try await busyWaitDuring {
                try self.parentOhttpStateMachine.receiveKey(
                    wrappedKey,
                    privateKey: ohttpKey.cachedKey,
                    responseBypassMode: parameters.responseBypassMode
                )
            }
            self.responseEncapsulator = completedHandshake.outboundStream
            if parameters.requestedNack {
                self.encodedRequestContinuation.yield(.nackAndExit(.init(
                    parameters,
                    nodeAppData: self.nodeAppData,
                    launchdJobInstanceUUID: self.jobUUID,
                    supportApps: []
                )))
            } else {
                // Force-unwrap is fine as we know the OHTTP state machine must have unwrapped the key at this point
                try self.requestSecrets.provide(dataEncryptionKey: self.parentOhttpStateMachine.dataEncryptionKey!)
                // flush any _actual_ request data to the cloud app
                for chunk in completedHandshake.pendingInboundData {
                    self.encodedRequestContinuation.yield(.chunk(.init(chunk: chunk.chunk)))
                }
            }
        }
    }

    @inline(never)
    @_optimize(none)
    func busyWaitDuring<T>(synchronousTask: () throws -> T) async throws -> T {
        let task = Task(priority: .low) {
            var iterations = 0
            while !Task.isCancelled {
                iterations += 1
            }
            return iterations
        }
        let result = try synchronousTask()
        task.cancel()
        let _ = await task.value
        return result
    }

    func teardown() async {
        self.encodedRequestContinuation.yield(.teardown)
    }

    func abandon() async throws {
        CloudBoardMessengerCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            message: "Received request to abandon job"
        ).log(to: Self.tracingLogger, level: .default)
        self.abandoned = true
        self.encodedRequestContinuation.yield(.abandon)
    }

    public func run() async throws {
        // Obtain initial set of SEP-backed node keys from the attestation daemon
        // the jobhelper is responsible for registering us for key rotation notifications
        defer {
            if !self.warmupReceived {
                self.workloadPromise.fail(with: CloudBoardMessengerError.warmupNeverCalled)
            }
        }
        do {
            CloudBoardMessengerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Requesting OHTTP node keys from attestation daemon"
            ).log(to: Self.tracingLogger, level: .default)
            let keySet = try await attestationClient.requestAttestedKeySet()
            self.nodeAppData = keySet.currentKey.appData

            CloudBoardMessengerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received OHTTP node keys from attestation daemon"
            ).log(attestedKeySet: keySet, to: Self.tracingLogger, level: .default)
            try self.ohttpKeyStateMachine.updateKeys(keys: keySet)

            var bufferedResponses = [FinalizableChunk<Data>]()
            var receivedFinal = false
            for await response in self.responseStream {
                switch response {
                case .chunk(let response):
                    let automatedDeviceGroupDimension = !(
                        self.requestParameters?.plaintextMetadata.automatedDeviceGroup
                            .isEmpty ?? true
                    )
                    let featureId = self.requestParameters?.plaintextMetadata.featureID ?? ""
                    let bundleId = self.requestParameters?.plaintextMetadata.bundleID ?? ""
                    let inferenceId = self.requestParameters?.plaintextMetadata
                        .workloadParameters[workloadParameterInferenceIDKey]?.first

                    defer { self.metrics.emit(Metrics.Messenger.TotalResponseChunksInBuffer(
                        value: 0,
                        automatedDeviceGroup: automatedDeviceGroupDimension,
                        featureId: featureId,
                        bundleId: bundleId,
                        inferenceId: inferenceId
                    )) }
                    self.metrics.emit(Metrics.Messenger.TotalResponseChunksReceivedCounter(
                        action: .increment,
                        automatedDeviceGroup: automatedDeviceGroupDimension,
                        featureId: featureId,
                        bundleId: bundleId,
                        inferenceId: inferenceId
                    ))
                    self.metrics.emit(
                        Metrics.Messenger.TotalResponseChunkReceivedSizeHistogram(
                            size: response.chunk.count,
                            automatedDeviceGroup: automatedDeviceGroupDimension,
                            featureId: featureId,
                            bundleId: bundleId,
                            inferenceId: inferenceId
                        )
                    )

                    CloudBoardMessengerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        message: "Received response"
                    ).log(response: response, to: Self.tracingLogger, level: .debug)
                    // If we haven't received the decryption key and with that set up the encapsulator, we have to
                    // buffer responses until we do
                    if self.responseEncapsulator == nil {
                        CloudBoardMessengerCheckpoint(
                            logMetadata: self.logMetadata(spanID: self.spanID),
                            message: "Buffering encoded response until OHTTP encapsulation is set up"
                        ).log(to: Self.tracingLogger, level: .default)
                        bufferedResponses.append(response)
                        self.metrics.emit(Metrics.Messenger.TotalResponseChunksInBuffer(
                            value: bufferedResponses.count,
                            automatedDeviceGroup: automatedDeviceGroupDimension,
                            featureId: featureId,
                            bundleId: bundleId,
                            inferenceId: inferenceId
                        ))
                        self.metrics.emit(
                            Metrics.Messenger.TotalResponseChunksBufferedSizeHistogram(
                                size: response.chunk.count,
                                automatedDeviceGroup: automatedDeviceGroupDimension,
                                featureId: featureId,
                                bundleId: bundleId,
                                inferenceId: inferenceId
                            )
                        )
                    } else {
                        for response in bufferedResponses + [response] {
                            let responseMessage = try self.responseEncapsulator!.encapsulate(
                                response.chunk,
                                final: response.isFinal
                            )
                            CloudBoardMessengerCheckpoint(
                                logMetadata: self.logMetadata(spanID: self.spanID),
                                message: "Sending encapsulated response"
                            ).log(response: response, to: Self.tracingLogger, level: .debug)
                            await self.server.sendWorkloadResponse(.responseChunk(.init(
                                encryptedPayload: responseMessage,
                                isFinal: response.isFinal
                            )))
                            if response.isFinal {
                                receivedFinal = true
                            }
                            self.metrics.emit(Metrics.Messenger.TotalResponseChunksSentCounter(
                                action: .increment,
                                automatedDeviceGroup: automatedDeviceGroupDimension,
                                featureId: featureId,
                                bundleId: bundleId,
                                inferenceId: inferenceId
                            ))
                        }
                        bufferedResponses = []
                        self.metrics.emit(Metrics.Messenger.TotalResponseChunksInBuffer(
                            value: 0,
                            automatedDeviceGroup: automatedDeviceGroupDimension,
                            featureId: featureId,
                            bundleId: bundleId,
                            inferenceId: inferenceId
                        ))
                    }
                case .findWorker(let query, let negotiate):
                    CloudBoardMessengerCheckpoint(
                        logMetadata: self.logMetadata(spanID: query.spanID),
                        message: "Received findWorker request"
                    ).log(
                        workerID: query.workerID,
                        serviceName: query.serviceName,
                        routingParameters: query.routingParameters,
                        to: Self.tracingLogger,
                        level: .debug
                    )
                    await self.server.sendWorkloadResponse(.findWorker(query: query, negotiate: negotiate))
                case .workerNegotiatePickResponse(let workerID, let selectableEnsembles):
                    CloudBoardMessengerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        message: "Received NegotiatePick response for worker"
                    ).log(workerID: workerID, to: Self.tracingLogger, level: .debug)
                    await self.server.sendWorkloadResponse(.workerNegotiatePickResponse(
                        workerID,
                        selectableEnsembles: selectableEnsembles
                    ))
                case .workerDecryptionKey(let workerID, let keyID, let encapsulatedKey):
                    CloudBoardMessengerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        message: "Received decryption key for worker"
                    ).log(workerID: workerID, to: Self.tracingLogger, level: .debug)
                    await self.server.sendWorkloadResponse(.workerDecryptionKey(
                        workerID,
                        keyID: keyID,
                        encapsulatedKey
                    ))
                case .workerRequestMessage(let workerID, let message):
                    CloudBoardMessengerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        message: "Received worker request message"
                    ).log(workerID: workerID, to: Self.tracingLogger, level: .debug)
                    await self.server.sendWorkloadResponse(.workerRequestMessage(
                        workerID,
                        message.chunk,
                        isFinal: message.isFinal
                    ))
                case .workerRequestEOF(let workerID):
                    CloudBoardMessengerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        message: "Received worker EOF"
                    ).log(workerID: workerID, to: Self.tracingLogger, level: .debug)
                    await self.server.sendWorkloadResponse(.workerRequestEOF(workerID))
                case .workerError(let workerID):
                    CloudBoardMessengerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        message: "Received worker error"
                    ).log(workerID: workerID, to: Self.tracingLogger, level: .debug)
                    await self.server.sendWorkloadResponse(.workerError(workerID))
                case .jobHelperEOF:
                    CloudBoardMessengerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        message: "Received jobHelper EOF"
                    ).log(to: Self.tracingLogger, level: .debug)
                    await self.server.sendWorkloadResponse(.jobHelperEOF)
                case .requestExecutionError(let error):
                    CloudBoardMessengerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        message: "Received request execution error"
                    ).log(to: Self.tracingLogger, level: .debug)
                    await self.server.sendWorkloadResponse(.requestExecutionError(error))
                }
            }

            // Finish the request stream once the response stream has ended.
            self.encodedRequestContinuation.finish()

            if !receivedFinal, !self.abandoned {
                CloudBoardMessengerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "Encoded response stream finished without final response chunk"
                ).log(to: Self.tracingLogger, level: .error)
            } else {
                CloudBoardMessengerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "Finished encoded response stream"
                ).log(to: Self.tracingLogger, level: .default)
            }
        } catch {
            CloudBoardMessengerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Error while running CloudBoardMessenger",
                error: error
            ).log(to: Self.tracingLogger, level: .fault)
            self.ohttpKeyStateMachine.failIfWaiting(error: error)
            throw error
        }
    }

    func notifyAttestationClientReconnect() async {
        self.ohttpKeyStateMachine.resetKeys()

        // Obtain latest attestation set in case we missed update from cb_attestationd while we were disconnected
        do {
            CloudBoardMessengerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Requesting new attested key set."
            ).log(to: Self.tracingLogger, level: .default)
            let keySet = try await self.attestationClient.requestAttestedKeySet()
            CloudBoardMessengerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received OHTTP node keys from attestation daemon after disconnect."
            ).log(attestedKeySet: keySet, to: Self.tracingLogger, level: .default)
            try self.ohttpKeyStateMachine.updateKeys(keys: keySet)
        } catch {
            CloudBoardMessengerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Failed to obtain new OHTTP node keys from attestation daemon after disconnect.",
                error: error
            ).log(to: Self.tracingLogger, level: .fault)
            // This is not expected to happen.
            // Better to crash at this point and have a new cb_jobhelper instance come up
            fatalError("Failed to obtain new OHTTP node keys from attestation daemon after disconnect.")
        }
    }

    func notifyKeyRotated(newKeySet: CloudBoardAttestationDAPI.AttestedKeySet) async throws {
        Self.logger.log("Updating key set to:' \(newKeySet.description, privacy: .public)")
        try self.ohttpKeyStateMachine.updateKeys(keys: newKeySet)
    }
}

extension CloudBoardMessenger {
    func logMetadata(spanID: UInt64? = nil) -> CloudBoardJobHelperLogMetadata {
        return CloudBoardJobHelperLogMetadata(
            jobID: self.jobUUID,
            requestTrackingID: self.requestParameters?.requestID ?? "",
            spanID: spanID
        )
    }
}

package struct OHttpKeyStateMachine: ~Copyable {
    internal enum OHttpKeyStateMachineError: ReportableError, Equatable {
        case illegalStateTransition(String)
        case neverReceivedKeys

        var publicDescription: String {
            switch self {
            case .illegalStateTransition(let reason): "illegalStateTransition:\(reason)"
            case .neverReceivedKeys: "neverReceivedKeys"
            }
        }
    }

    enum OHttpKeyState {
        case uninitialised(attestedKeys: AttestedKeySet?)
        case initialised(LAContext)
        case available([CachedAttestedKey], LAContext)
        case awaitingKeys(Promise<[CachedAttestedKey], Error>, LAContext)
        case used
    }

    enum ConsumeKeyResult {
        case available([CachedAttestedKey])
        case waiting(Promise<[CachedAttestedKey], Error>)
    }

    internal var state = OHttpKeyState.uninitialised(attestedKeys: nil)

    deinit {
        if case .awaitingKeys(let promise, _) = self.state {
            promise.fail(with: OHttpKeyStateMachineError.neverReceivedKeys)
        }
    }

    mutating func initialiseLAContext(laContext: LAContext) throws {
        switch self.state {
        case .uninitialised(let attestedKeySet):
            if let attestedKeySet {
                self.state = try .available(Array(keySet: attestedKeySet, laContext: laContext), laContext)
            } else {
                self.state = .initialised(laContext)
            }
        case .initialised, .awaitingKeys, .available, .used:
            throw OHttpKeyStateMachineError.illegalStateTransition("LAContext initialised twice.")
        }
    }

    mutating func consumeAttestedKeys() throws -> ConsumeKeyResult {
        switch self.state {
        case .uninitialised:
            throw OHttpKeyStateMachineError.illegalStateTransition("Tried to consume key before initialised LAContext.")
        case .initialised(let laContext):
            let promise = Promise<[CachedAttestedKey], Error>()
            self.state = .awaitingKeys(promise, laContext)
            return .waiting(promise)
        case .available(let keys, _):
            self.state = .used
            return .available(keys)
        case .awaitingKeys(let promise, _):
            return .waiting(promise)
        case .used:
            throw OHttpKeyStateMachineError.illegalStateTransition("Tried to consume keys after they were used.")
        }
    }

    mutating func updateKeys(keys: AttestedKeySet) throws {
        switch self.state {
        case .uninitialised:
            self.state = .uninitialised(attestedKeys: keys)
        case .initialised(let laContext), .available(_, let laContext):
            self.state = try .available(Array(keySet: keys, laContext: laContext), laContext)
        case .awaitingKeys(let promise, let laContext):
            let keys = try Array(keySet: keys, laContext: laContext)
            self.state = .used
            promise.succeed(with: keys)
        case .used:
            // ignore any new updates from attestation server, since we are already using
            // or have used the keys and don't require a new one any more.
            ()
        }
    }

    mutating func resetKeys() {
        switch self.state {
        case .initialised, .awaitingKeys, .used:
            // Do nothing if either we don't have keys yet
            // or if they are already being used, or have been used.
            ()
        case .available(_, let laContext):
            self.state = .initialised(laContext)
        case .uninitialised:
            self.state = .uninitialised(attestedKeys: nil)
        }
    }

    mutating func failIfWaiting(error: Error) {
        if case .awaitingKeys(let promise, _) = self.state {
            promise.fail(with: error)
        }
        self.state = .used
    }
}

enum NodeKeyError: ReportableError {
    case unknownKeyID(String)
    case expiredKey(String)

    var publicDescription: String {
        let errorType = switch self {
        case .unknownKeyID: "unknownKeyID"
        case .expiredKey: "expiredKey"
        }
        return "nodeKey.\(errorType)"
    }
}

/// `ReportableJobHelperError` is  used to describe an error for which the underlying reason is reported back to
/// CloudBoard via a `WorkloadResponse`.
struct ReportableJobHelperError: Error {
    let wrappedError: Error
    let reason: FailureReason
}

struct CloudBoardMessengerCheckpoint: RequestCheckpoint {
    var requestID: String? {
        self.logMetadata.requestTrackingID
    }

    var operationName: StaticString

    var serviceName: StaticString = "cb_jobhelper"

    var namespace: StaticString = "cloudboard"

    var error: Error?

    var logMetadata: CloudBoardJobHelperLogMetadata

    var message: StaticString

    public init(
        logMetadata: CloudBoardJobHelperLogMetadata,
        operationName: StaticString = #function,
        message: StaticString,
        error: Error? = nil
    ) {
        self.logMetadata = logMetadata
        self.operationName = operationName
        self.message = message
        if let error {
            self.error = error
        }
    }

    public func log(to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        """)
    }

    public func log(request: FinalizableChunk<Data>, to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(String(describing: self.logMetadata.remotePID), privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        requestChunkSize=\(request.chunk.count, privacy: .public)
        requestChunkIsFinal=\(request.isFinal)
        """)
    }

    public func log(response: FinalizableChunk<Data>, to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        responseChunkSize=\(response.chunk.count, privacy: .public)
        responseIsFinal=\(response.isFinal)
        """)
    }

    public func log(keyID: String, to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        keyID=\(keyID, privacy: .public)
        """)
    }

    public func log(attestedKeySet: AttestedKeySet, to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        keySet=\(attestedKeySet, privacy: .public)
        """)
    }

    public func log(
        workerID: UUID,
        to logger: Logger,
        level: OSLogType = .default
    ) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        worker.uuid=\(workerID, privacy: .public)
        """)
    }

    public func log(
        workerID: UUID,
        serviceName: String,
        routingParameters: [String: [String]],
        to logger: Logger,
        level: OSLogType = .default
    ) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        worker.uuid=\(workerID, privacy: .public)
        serviceName=\(serviceName, privacy: .public)
        routingParameters=\(routingParameters, privacy: .public)
        """)
    }
}

struct CachedAttestedKey {
    var attestedKey: AttestedKey
    var cachedKey: any HPKEDiffieHellmanPrivateKey

    init(_ attestedKey: AttestedKey, laContext: LAContext) throws {
        switch attestedKey.key {
        case .keychain(let persistentKeyReference):
            do {
                let secKey = try Keychain.fetchKey(persistentRef: persistentKeyReference)
                let cryptoKitKey = try cbSignposter.withIntervalSignpost("CB.sep.cacheKey") {
                    try SecureEnclave.Curve25519.KeyAgreement.PrivateKey(
                        from: secKey,
                        authenticationContext: laContext
                    )
                }
                self.cachedKey = cryptoKitKey
                CloudBoardMessenger.logger.debug("""
                message=\("Obtained OHTTP key from keychain", privacy: .public)
                publicKey=\(cryptoKitKey.publicKey.rawRepresentation.base64EncodedString(), privacy: .public)
                """)
            } catch {
                CloudBoardMessengerCheckpoint(
                    logMetadata: .init(),
                    message: "Failed to obtain OHTTP key from keychain",
                    error: error
                ).log(to: CloudBoardMessenger.logger, level: .fault)
                fatalError("Failed to obtain OHTTP key from keychain: \(String(reportable: error))")
            }
        case .direct(let inMemoryKey):
            self.cachedKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: inMemoryKey)
        }

        self.attestedKey = attestedKey
    }

    var keyID: Data {
        self.attestedKey.keyID
    }

    var expiry: Date {
        self.attestedKey.expiry
    }
}

extension [CachedAttestedKey] {
    init(keySet: AttestedKeySet, laContext: LAContext) throws {
        self = []
        self.reserveCapacity(keySet.unpublishedKeys.count + 1)

        try self.append(CachedAttestedKey(keySet.currentKey, laContext: laContext))

        for unpublishedKey in keySet.unpublishedKeys {
            try self.append(CachedAttestedKey(unpublishedKey, laContext: laContext))
        }
    }
}

extension CachedAttestedKey: Equatable {
    static func == (lhs: CachedAttestedKey, rhs: CachedAttestedKey) -> Bool {
        return lhs.attestedKey == rhs.attestedKey
    }
}

extension OHttpKeyStateMachine.OHttpKeyState: Equatable {
    static func == (lhs: OHttpKeyStateMachine.OHttpKeyState, rhs: OHttpKeyStateMachine.OHttpKeyState) -> Bool {
        switch lhs {
        case .uninitialised(let keySet):
            if case .uninitialised(let otherKeySet) = rhs {
                return keySet == otherKeySet
            }
            return false
        case .initialised:
            if case .initialised = rhs {
                return true
            }
            return false
        case .available(let cachedKeys, _):
            if case .available(let otherCachedKeys, _) = rhs {
                return cachedKeys == otherCachedKeys
            }
            return false
        case .awaitingKeys:
            if case .awaitingKeys = rhs {
                return true
            }
            return false
        case .used:
            if case .used = rhs {
                return true
            }
            return false
        }
    }
}

extension OHttpKeyStateMachine.ConsumeKeyResult: Equatable {
    static func == (lhs: OHttpKeyStateMachine.ConsumeKeyResult, rhs: OHttpKeyStateMachine.ConsumeKeyResult) -> Bool {
        switch lhs {
        case .available(let cachedKeys):
            if case .available(let rhsCachedKeys) = rhs {
                return cachedKeys == rhsCachedKeys
            }
            return false
        case .waiting:
            if case .waiting = rhs {
                return true
            }
            return false
        }
    }
}
