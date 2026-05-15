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
//  EnsembleWardenClient.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 11/11/2024.
//

private import AppServerSupport.OSLaunchdJob
private import CryptoKit
private import EnsembleWardenCommon
private import EnsembleWardenXPCAPI
public import Foundation
public import IOSurface
internal import os
private import Synchronization
private import System
@_spi(SessionConnectionCompatibility) @preconcurrency private import XPC
private import XPCOverlay
import XPCPrivate


/// EnsembleWardenClient allows transfering of sensitive assets between nodes in an ensemble,
/// ensuring that they are encrypted to a key scoped to the ensemble.
///
/// To use `EnsembleWardenClient`, adopters should have pre-established a key across
/// an ensemble, known as `keyID`.
///
/// The usual flow for using an ``EnsembleWardenClient`` is:
/// 1. `let client = EnsembleWardenClient()` to generate a client that will be used for a single request.
/// 2. `client.prewarm()` to start a fresh ensemblewardend process. The process takes ~40ms to start, so
/// adopters may wish to call this early on.
/// 3. `client.supply(cryptoHandles: requestID: spanID)` when they have
/// received a request and have handles for its key material.
/// 4. `client.publish()`/`client.fetch()` to do the actual fetching/publishing.
/// 5. `client.finish()` when finished handling the request.
public final class EnsembleWardenClient: Sendable {
    private let clientImplementation: EnsembleWardenClientImplementation<OSMetricsBridge>
    private let logger = Logger(subsystem: "com.apple.ensemblewarden", category: "EnsembleWarden")
    public init() {
        self.clientImplementation = EnsembleWardenClientImplementation(metricsFactory: OSMetricsBridge())
    }
    public func prewarm(spanID: UInt64) throws {
        try self.clientImplementation.prewarm(spanID: spanID)
    }

    public func prefault(ioSurfaces: [IOSurface], spanID: UInt64) async throws {
        try await self.clientImplementation.prefault(ioSurfaces: ioSurfaces, spanID: spanID)
    }

    public func supply(cryptoHandles: EnsembleWardenCryptoHandles,
                       requestID: UUID, spanID: UInt64) async throws -> FollowerTokens {
        try await self.clientImplementation.supply(cryptoHandles: cryptoHandles, requestID: requestID, spanID: spanID)
    }
    public consuming func finish(spanID: UInt64=0) async throws {
        try await self.clientImplementation.finish(spanID: spanID)
    }

    public func publish(serializedXPCRequest: Data, privateData: [IOSurface], purpose: KVCacheTransferPurpose, spanID: UInt64) async throws {
        try await self.clientImplementation.publish(serializedXPCRequest: serializedXPCRequest, privateData: privateData, purpose: purpose, spanID: spanID)
    }
    public func fetch(serializedXPCRequest: Data, spanID: UInt64) async throws -> [IOSurface] {
        try await self.clientImplementation.fetch(serializedXPCRequest: serializedXPCRequest, spanID: spanID)
    }
    public func fetch(serializedXPCRequest: Data, spanID: UInt64, range: ClosedRange<Int>) async throws -> [IOSurface] {
        try await self.clientImplementation.fetch(serializedXPCRequest: serializedXPCRequest, spanID: spanID, range: range)
    }

    public func dropAll() async throws {
        try await self.clientImplementation.dropAll()
    }
}

package final class EnsembleWardenClientImplementation<Factory: MetricsFactory>: Sendable {
    /// This must match the "_managedBy" key in the launchd plist of ensemblewardend.
    private let managedByLabel = "com.apple.cloudos.ensemblewardenframework"

    private let xpcServiceName: String
    /// By default we use process isolation of ensemblewardend.
    ///
    /// This is built using launchd's OSLaunchdJob. However this isn't really testable.
    /// We therefore need to turn off this process isolation for our internal testing.
    private let processIsolation: Bool
    private let logger = Logger(subsystem: "com.apple.ensemblewarden", category: "EnsembleWarden")
    private let signposter: OSSignposter
    /// ensembleWardenID created for logging before requestID given.
    private let ensembleWardenID: UUID = UUID()
    private let ensembleWardenMetrics: EnsembleWardenMetrics<Factory>

    private enum State: Sendable {
        /// We haven't yet connected to a daemon, so we can create a new daemon+connection.
        case notYetConnected
        ///  We have an active connection but no request ID or key ID.
        case prewarmed(XPCSession)
        /// We are in the process of sending crypto handles.
        case sendingCryptoHandles(XPCSession)
        /// We have an active connection to a daemon and request ID and key ID with requestID being passed through the state.
        case ready(XPCSession, UUID)
        /// We *had* a connection to a daemon but it was invalidated/interrupted.
        /// We can't create a new connection since we have a one-time access token to the key used to encrypt/decrypt the session.
        case noLongerValid
    }

    private let state: Mutex<State> = .init(.notYetConnected)

    // Deinit is a bit frowned upon, but we're just cleaning up a connection here.
    deinit {
        self.state.withLock { state in
            switch state {
            case .ready(let session, _): session.cancel(reason: "EnsembleWardenClient deinit")
            default: break
            }
        }
    }


    /// Initialiser for connecting to services that aren't kv-cache-transfer.
    ///
    /// Allows us to specify custom xpcServiceNames.
    package init(xpcServiceName: String, processIsolation: Bool = true, requestID: UUID, metricsFactory: Factory) {
        self.xpcServiceName = xpcServiceName
        self.processIsolation = processIsolation
        self.signposter = OSSignposter(logger: self.logger)
        self.ensembleWardenMetrics = EnsembleWardenMetrics(metricsFactory: metricsFactory)
    }

    /// Creates a new EnsembleWardenClient.
    fileprivate convenience init(metricsFactory: Factory) {
        self.init(xpcServiceName: kEnsembleWardenAPIXPCLocalServiceName, processIsolation: true, metricsFactory: metricsFactory)
    }

    package init(xpcServiceName: String, processIsolation: Bool = true, metricsFactory: Factory) {
        self.xpcServiceName = xpcServiceName
        self.processIsolation = processIsolation
        self.signposter = OSSignposter(logger: self.logger)
        self.ensembleWardenMetrics = EnsembleWardenMetrics(metricsFactory: metricsFactory)
    }

    /// Starts up an instance of ensemblewardend so that the costs of process startup are paid before
    /// we hit the hot-path of requests.
    package func prewarm(spanID: UInt64) throws {
        try self.state.withLock { state in
            switch state {
            case .notYetConnected:
                let session = try doPrewarm()
                state = .prewarmed(session)
            case .sendingCryptoHandles:
                throw EnsembleWardenError.invalidStateTransition
            case .prewarmed, .ready(_, _):
                logger.warning("""
                                Client prewarmed twice. \
                                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public)
                                """)
            case .noLongerValid:
                throw EnsembleWardenError.clientNoLongerActive
            }
        }
    }

    private func doPrewarm() throws -> XPCSession {
        let prewarmInterval = self.signposter.beginInterval("EW.prewarm.signpost")
        defer {
            self.signposter.endInterval("EW.prewarm.signpost", prewarmInterval)
        }
        logger.log("""
            Prewarming ensemblewardend. \
            ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
            span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
            """)
        do {
            let session = try self.processIsolation ? freshProcess() : singleProcess()
            logger.log("Sending prewarm message")
            // Send an empty start message for prewarming
            try session.sendSync(EnsembleWardenDaemonXPC.Request.empty(.init()))
            logger.debug("""
                Finished prewarming ensemblewardend. \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                """)
            return session
        } catch {
            logger.error("""
                Error prewarming ensemblewardend. \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public) \
                error=\(String(reportable: error), privacy: .public)
                """)
            throw error
        }
    }

    private func send(cryptoHandles: EnsembleWardenCryptoHandles, session: XPCSession,
                      requestID: UUID, spanID: UInt64) async throws -> [Int: UUID] {
        logger.log("""
                Sending cryptoHandles. \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                request_id=\(requestID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
        do {

            let message = EnsembleWardenDaemonXPC.Start(
                ensemblePorterConnection: cryptoHandles.ensemblePorterHandle,
                followerToken: cryptoHandles.followerToken,
                requestID: requestID)
            let response = try await session.sendXPC(request: message)
            switch response {
            case .success(let tokens):
                logger.log("""
                        EnsembleWardenCryptoHandles sent. \
                        ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                        request_id=\(requestID, privacy: .public) \
                        span_id=\(spanID.hexEncoded, privacy: .public)
                        """)
                return tokens
            case .failure(let error): throw error
            }
        } catch {
            logger.error("""
                Error sending key. \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public) \
                error=\(String(reportable: error), privacy: .public)
                """)
            throw error
        }
    }

    /// Provide a single-use key access token that ensemblewardend can use to fetch a key and requestid.
    ///
    /// This is usually called once the dance with ensembled and cbjobhelper has distributed a key to the
    /// ET ensemble.
    /// - Parameters:
    ///   - cryptoHandles: The collection of handles that let ensemblewarden encrypt/decrypt using the correct keys.
    ///   - requestID: The request ID that was used to request the key.
    ///   - spanID: The span ID to use for logging.
    /// - Returns: A dictionary that maps nodeID->a token that can be used by that node to connect to an
    ///     ensemblewarden on the followers.
    package func supply(cryptoHandles: EnsembleWardenCryptoHandles,
                       requestID: UUID, spanID: UInt64) async throws -> FollowerTokens {
        do {
            return try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
                try await PrismTracing.withSpan(name: "EnsembleWardenSupplyKey") {
                    return try await self.doSupply(cryptoHandles: cryptoHandles)
                }
            }
        } catch {
            logger.error("""
                Supply failed. \
                error=\(String(reportable: error), privacy: .public) \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
            throw error
        }
    }

    private func doSupply(cryptoHandles: EnsembleWardenCryptoHandles) async throws -> FollowerTokens {
        let session = try self.state.withLock { state in
            switch state {
            case .notYetConnected:
                let session = try doPrewarm()
                state = .sendingCryptoHandles(session)
                return session
            case .prewarmed(let session):
                state = .sendingCryptoHandles(session)
                return session
            case .ready(_, _), .sendingCryptoHandles(_):
                logger.error("""
                            Supplied key_id and request_id twice. \
                            ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                            request_id=\(PrismTracing.requestID, privacy: .public) \
                            span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                            """)
                throw EnsembleWardenError.keyIDSuppliedTwice
            case .noLongerValid:
                logger.error("""
                            Client closed and finished. \
                            ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                            request_id=\(PrismTracing.requestID, privacy: .public) \
                            span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                            """)
                throw EnsembleWardenError.invalidStateTransition
            }
        }

        logger.log("""
            Supply called. \
            has_follower_token=\(cryptoHandles.followerToken != nil, privacy: .public) \
            has_ensemble_porter_handle=\(cryptoHandles.ensemblePorterHandle != nil, privacy: .public)
            """)
        let rawTokens = try await send(cryptoHandles: cryptoHandles, session: session,
                                        requestID: PrismTracing.requestID, spanID: PrismTracing.spanID)
        let followerTokens = FollowerTokens(tokens: rawTokens)

        try self.state.withLock { state in
            switch state {
            case .sendingCryptoHandles(_): state = .ready(session, PrismTracing.requestID)
            default: throw EnsembleWardenError.invalidStateTransition
            }
        }

        return followerTokens
    }

    private func freshProcess() throws -> XPCSession {
        logger.log("""
            Starting new ensemblewardend. \
            ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
            span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
            """)
        var instanceUUID = UUID()
        let managedJobs = try OSLaunchdJob.copyJobsManaged(by: EnsembleWardenConstants.managedByEnsembleWardenFrameworkLabel)
        // Only get the original launchd job, not all instances of this job
        let managedJobsWithoutInstances = managedJobs.filter { job in
            guard let jobInfo = job.getCurrentJobInfo() else {
                return false
            }
            return jobInfo.instance == nil
        }
        guard managedJobsWithoutInstances.count == 1, let job = managedJobsWithoutInstances.first else {
            logger.error("""
                Incorrect managed job count. \
                expected=\(1) \
                actual=\(managedJobs.count) \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                """)
            throw EnsembleWardenError.launchdMisconfiguration
        }
        logger.log("""
                    Creating new process instance. \
                    process_instance_uuid=\(instanceUUID, privacy: .public) \
                    existing_managed_job_instances=\(managedJobs.count) \
                    ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                    span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                    """)
        let jobInstance = try withUnsafeMutablePointer(to: &instanceUUID) { id in
            try job.createInstance(id)
        }

        logger.log("""
                    Creating process-isolated XPC connection. \
                    mach_service=\(self.xpcServiceName, privacy: .public) \
                    instance_uuid=\(instanceUUID, privacy: .public) \
                    ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                    span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                    """)
        let xpcConnection = xpc_connection_create_mach_service(xpcServiceName, nil, 0)

        withUnsafeMutablePointer(to: &instanceUUID) { id in
            xpc_connection_set_oneshot_instance(xpcConnection, id)
        }
        jobInstance.monitor(on: DispatchQueue.global()) { jobInfo, err in
            self.handleJobInfoUpdate(jobInfo, errno: err, jobInstance: jobInstance)
        }

        logger.log("Creating XPC session")
        return try XPCSession(fromConnection: xpcConnection) { error in
            self.logger.log("""
                            XPC session cancelled. \
                            error=\(error, privacy: .public) \
                            ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                            span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                            """)
            self.state.withLock { $0 = .noLongerValid }
        }
    }

    private func handleJobInfoUpdate(_ jobInfo: OSLaunchdJobInfo?, errno: errno_t, jobInstance: OSLaunchdJob) {
        do {
            let managedJobCount = try OSLaunchdJob.copyJobsManaged(by: self.managedByLabel).count
            // note: need to subtract 1 because the plist is included in the number below
            self.ensembleWardenMetrics.launchdJobs.set(Int64(managedJobCount-1))
            logger.log("Fetched running launchd jobs. job_count=\(Int64(managedJobCount-1))")
        } catch {
            logger.log("Unable to fetch launchd managed jobs. error=\(String(reportable: error), privacy: .public)")
        }
        guard let jobInfo else {
            self.logger.error("""
                Unexpectedly received event with no jobInfo. \
                errno=\(errno) \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public)
                """)
            return
        }
        switch jobInfo.state {
        case .neverRan:
            self.logger.log("""
                ensemblewardend launchd job reported neverRan. \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public)
                """)
        case .running:
            self.logger.log("""
                ensemblewardend launchd job running. \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public)
                """)
        case .spawnFailed:
            let errNo = Errno(rawValue: jobInfo.lastSpawnError)
            self.logger.log("""
                ensemblewardend launchd spawn failed. \
                errno=\(errNo, privacy: .public) \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public)
                """)
        case .exited:
            self.logger.log("""
                ensemblewardend process reported exit. \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public)
                """)
            jobInstance.cancelMonitor()
        }
    }

    private func singleProcess() throws -> XPCSession {
        logger.log("""
                    Creating XPC session. \
                    mach_service=\(self.xpcServiceName, privacy: .public) \
                    ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                    span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                    """)
        let requestID = PrismTracing.requestID
        return try XPCSession(machService: self.xpcServiceName) { error in
            self.logger.log("""
                            XPC session cancelled. \
                            error=\(error, privacy: .public) \
                            ensemble_warden_id=\(self.ensembleWardenID, privacy: .public)
                            """)
            self.state.withLock { $0 = .noLongerValid }
        }
    }

}

// MARK: Implementation API
extension EnsembleWardenClientImplementation {
    /// Ends the current EnsembleWarden session.
    package consuming func finish(spanID: UInt64=0) async throws {
        let finishInterval = self.signposter.beginInterval("EW.finish.signpost")
        defer {
            self.signposter.endInterval("EW.finish.signpost", finishInterval)
        }
        let (session, requestID): (XPCSession?, UUID?) = try self.state.withLock { state in
            switch state {
            case .notYetConnected:
                state = .noLongerValid
                return (nil, nil)
            case .prewarmed(let session), .sendingCryptoHandles(let session):
                state = .noLongerValid
                return (session, nil)
            case .ready(let session, let requestID):
                state = .noLongerValid
                return (session, requestID)
            case .noLongerValid:
                logger.error("Client already finished")
                throw EnsembleWardenError.clientNoLongerActive
            }
        }
        if let session {
            if let requestID {
                logger.log("""
                   Ending EnsembleWarden connection. \
                   ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                   request_id=\(requestID, privacy: .public) \
                   span_id=\(spanID.hexEncoded, privacy: .public)
                   """)
            } else {
                logger.log("""
                   Ending EnsembleWarden connection. \
                   ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                   span_id=\(spanID.hexEncoded, privacy: .public)
                   """)
            }
            session.cancel(reason: "close")
        }
    }

    /// Fetch ioSurface and decrypt them so they can be used by the caller
    /// - Parameters:
    ///   - serializedXPCRequest: An serialised request protobuf that identifies the ioSurfaces to be fetched.
    ///   - spanID: A UUID to help with logging
    /// - Returns: Decrypted private data in IOSurfaces
    package func fetch(serializedXPCRequest: Data, spanID: UInt64) async throws -> [IOSurface] {
        let fetchInterval = self.signposter.beginInterval("EW.fetch.signpost")
        defer {
            self.signposter.endInterval("EW.fetch.signpost", fetchInterval)
        }

        do {
            return try await self.ensembleWardenMetrics.reportingClientMetrics(operationName: "fetch") {
                let (session, requestID) = try self.state.withLock { state in
                    switch state {
                    case .notYetConnected, .prewarmed(_), .sendingCryptoHandles:
                        throw EnsembleWardenError.keyIDNotSupplied
                    case .ready(let session, let requestID):
                        return (session, requestID)
                    case .noLongerValid:
                        throw EnsembleWardenError.clientNoLongerActive
                    }
                }
                return try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
                    try await PrismTracing.withSpan(name: "EnsembleWardenFetch") {
                        return try await self.doFetch(serializedXPCRequest: serializedXPCRequest, session: session)
                    }
                }
            }
        } catch {
            logger.error("""
                Fetch failed. \
                error=\(String(reportable: error), privacy: .public) \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
            throw error
        }
    }

    private func doFetch(serializedXPCRequest: Data, session: XPCSession) async throws -> [IOSurface] {
        let fetchMessage = EnsembleWardenDaemonXPC.Fetch(
            serializedXPCRequest: serializedXPCRequest,
            requestID: PrismTracing.requestID,
            spanID: PrismTracing.spanID)

        let response = try await session.sendXPC(request: fetchMessage)
        let ioSurfaces: [IOSurface]
        switch response {
        case .success(let returned): ioSurfaces = returned
        case .failure(let error): throw error
        }
        _ = try ioSurfaces.map { try $0.takeOwnership() }
        return ioSurfaces
    }

    /// Fetch a specific range of the ioSurface data and decrypt it so it can
    /// be used by the caller
    /// - Parameters:
    ///   - serializedXPCRequest: A serialized request protobuf that
    ///   identifies the ioSurfaces to be fetched
    ///   - spanID: A UUID to help with logging
    ///   - range: The byte range to fetch within the ioSurfaces
    /// - Returns: Decrypted private data in IOSurfaces
    /// - Note: If the request identifies multiple ioSurfaces then the range
    /// must be valid for all of them otherwise an error is thrown.
    package func fetch(
        serializedXPCRequest: Data,
        spanID: UInt64,
        range: ClosedRange<Int>
    ) async throws -> [IOSurface] {
        guard range.lowerBound >= 0, range.upperBound >= 0 else {
            throw EnsembleWardenError.invalidIOSurfaceRange
        }

        let inSurfaces = try await fetch(
            serializedXPCRequest: serializedXPCRequest, spanID: spanID)
        var outSurfaces: [IOSurface] = []

        /// Only one surface is used in practice. However, the API uses arrays
        /// of surfaces so assume we want to trim them all if there is more
        /// than one.
        for inSurface in inSurfaces {
            guard let outSurface = try IOSurface(
                from: inSurface, at: range) else {
                throw EnsembleWardenError.failedToCreateIOSurface
            }
            outSurfaces.append(outSurface)
        }

        return outSurfaces
    }

    /// Performs a publish operation to the ensemble warden daemon.
    /// - Parameters:
    ///   - serializedXPCRequest: The serialized XPC request to publish.
    ///   - privateData: The private data to publish.
    ///   - purpose: The purpose of the KV$ transfer that we're about to initiate. Eg is it for FT/ET?
    ///   - spanID: The span ID to use for this operation.
    package func publish(serializedXPCRequest: Data, privateData: [IOSurface], purpose: KVCacheTransferPurpose, spanID: UInt64) async throws {
        let publishInterval = self.signposter.beginInterval("EW.publish.signpost")
        defer {
            self.signposter.endInterval("EW.publish.signpost", publishInterval)
        }
        do {
            try await self.ensembleWardenMetrics.reportingClientMetrics(operationName: "publish") {
                let (session, requestID) = try self.state.withLock { state in
                    switch state {
                    case .notYetConnected, .prewarmed(_), .sendingCryptoHandles:
                        logger.error("KeyID not yet supplied")
                        throw EnsembleWardenError.keyIDNotSupplied
                    case .ready(let session, let requestID):
                        return (session, requestID)
                    case .noLongerValid:
                        logger.error("Client no active")
                        throw EnsembleWardenError.clientNoLongerActive
                    }
                }
                return try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
                    try await PrismTracing.withSpan(name: "EnsembleWardenPublish") {
                        let message = EnsembleWardenDaemonXPC.Publish(
                            serializedXPCRequest: serializedXPCRequest,
                            ioSurfaces: privateData,
                            purpose: .init(purpose: purpose),
                            requestID: PrismTracing.requestID,
                            spanID: PrismTracing.spanID)
                        let response = try await session.sendXPC(request: message)
                        switch response {
                            case .success(_): break
                            case .failure(let error): throw error
                        }
                    }
                }
            }
        } catch {
            logger.error("""
                Publish failed. \
                error=\(String(reportable: error), privacy: .public) \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
            throw error
        }
    }

    /// Prefaults IOSurfaces to page them into memory.
    ///
    /// - Parameters:
    ///   - ioSurfaces: The IOSurfaces to prefault
    ///   - spanID: The span ID to use for this operation
    package func prefault(ioSurfaces: [IOSurface], spanID: UInt64) async throws {
        try await self.ensembleWardenMetrics.reportingClientMetrics(operationName: "prefault") {
            let (session, _) = try self.getSession()
            return try await PrismTracing.withSpan(name: "EnsembleWardenPrefault") {
                let request = EnsembleWardenDaemonXPC.Prefault(
                    ioSurfaces: ioSurfaces,
                    requestID: PrismTracing.requestID,
                    spanID: PrismTracing.spanID)
                let response = try await session.sendXPC(request: request)
                switch response {
                case .success(_): break
                case .failure(let error): throw error
                }
            }
        }
    }

    /// Drops all cached data in EnsembleTransport.
    package func dropAll() async throws {
        let interval = self.signposter.beginInterval("EW.dropAll.signpost")
        defer {
            self.signposter.endInterval("EW.dropAll.signpost", interval)
        }

        do {
            return try await self.ensembleWardenMetrics.reportingClientMetrics(
                operationName: "dropAll") {

                let session = try self.state.withLock { state in
                    switch state {
                    case .notYetConnected:
                        // Auto-connect if not yet connected, similar to doSupply()
                        let session = try self.doPrewarm()
                        state = .prewarmed(session)
                        return session
                    case .prewarmed(let session), .sendingCryptoHandles(let session), .ready(let session, _):
                        return session
                    case .noLongerValid:
                        throw EnsembleWardenError.clientNoLongerActive
                    }
                }

                logger.log("""
                    Calling dropAll. \
                    ensemble_warden_id=\(self.ensembleWardenID, privacy: .public)
                    """)

                let request = EnsembleWardenDaemonXPC.DropAll()
                let response = try await session.sendXPC(request: request)
                switch response {
                case .success(_): break
                case .failure(let error): throw error
                }
            }
        } catch {
            logger.error("""
                DropAll failed. \
                error=\(String(reportable: error), privacy: .public) \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public)
                """)
            throw error
        }
    }
}

// MARK: Public API - EnsembleTransport backend
extension EnsembleWardenClient {
    public func publish(identifier: String, privateData: IOSurface, privateMetadata: IOSurface?, ttl: Duration, purpose: KVCacheTransferPurpose, spanID: UInt64 ) async throws {
        try await self.clientImplementation.publish(identifier: identifier, privateData: privateData, privateMetadata: privateMetadata, ttl: ttl, purpose: purpose, spanID: spanID)
    }

    public func fetch(identifier: String, range: ClosedRange<Int>?, host: String, spanID: UInt64) async throws -> IOSurface {
        try await self.clientImplementation.fetch(identifier: identifier, range: range, host: host, spanID: spanID)
    }

    public func fetchMetadata(identifier: String, host: String, spanID: UInt64) async throws -> IOSurface? {
        try await self.clientImplementation.fetchMetadata(identifier: identifier, host: host, spanID: spanID)
    }

    public func delete(identifier: String, spanID: UInt64) async throws {
        try await self.clientImplementation.delete(identifier: identifier, spanID: spanID)
    }

    public func delete(identifier: String, host: String, spanID: UInt64) async throws {
        try await self.clientImplementation.delete(identifier: identifier, host: host, spanID: spanID)
    }
}

// MARK: Implementation API - EnsembleTransport backend
extension EnsembleWardenClientImplementation {
    /// Publish IOSurface data to the EnsembleWarden daemon.
    /// This version of publish uses EnsembleTransport as the backend.
    /// - Parameters:
    ///   - identifier: A string used to identify the data later when fetching
    ///   - privateData: The private data to publish
    ///   - privateMetadata: Optional additional metadata associated with the
    ///   specified identifier
    ///   - ttl: The length of time to keep the data available before it is
    ///   automatically purged
    ///   - purpose: The purpose of the KV$ transfer that we're about to
    ///   initiate. Eg is it for FT/ET?
    ///   - spanID: The span ID to use for this operation
    package func publish(
        identifier: String,
        privateData: IOSurface,
        privateMetadata: IOSurface?,
        ttl: Duration,
        purpose: KVCacheTransferPurpose,
        spanID: UInt64
    ) async throws {
        let interval = self.signposter.beginInterval("EW.publish2.signpost")
        defer {
            self.signposter.endInterval("EW.publish2.signpost", interval)
        }
        do {
            try await self.ensembleWardenMetrics.reportingClientMetrics(
                operationName: "publish2") {
                let (session, requestID) = try self.getSession()
                return try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
                    try await PrismTracing.withSpan(name: "EnsembleWardenPublish2Client") {
                        try await self.doPublish2(identifier: identifier, privateData: privateData, privateMetadata: privateMetadata, ttl: ttl, purpose: purpose, session: session)
                    }
                }
            }
        } catch {
            logger.error("""
                Publish2 failed. \
                error=\(String(reportable: error), privacy: .public) \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
            throw error
        }
    }

    private func doPublish2(
        identifier: String,
        privateData: IOSurface,
        privateMetadata: IOSurface?,
        ttl: Duration,
        purpose: KVCacheTransferPurpose,
        session: XPCSession
    ) async throws {
        logger.debug("""
            Publishing IOSurface to ensemblewardend (new API). \
            ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
            request_id=\(PrismTracing.requestID, privacy: .public) \
            span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
            """)
        let request = EnsembleWardenDaemonXPC.Publish2(
            identifier: identifier,
            privateData: privateData,
            privateMetadata: privateMetadata,
            ttl: ttl,
            purpose: .init(purpose: purpose),
            requestID: PrismTracing.requestID,
            spanID: PrismTracing.spanID)
        logger.debug("""
            Created session. \
            ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
            request_id=\(PrismTracing.requestID, privacy: .public) \
            span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
            """)
        let response = try await session.sendXPC(request: request)
        switch response {
        case .success(_): break
        case .failure(let error): throw error
        }
    }

    /// Fetch IOSurface data associated with the specified identifier
    /// and decrypt it so it can be used by the caller.
    /// This version of fetch uses EnsembleTransport as the backend.
    /// - Parameters:
    ///   - identifier: A string identifying the data to fetch
    ///   - range: The byte range to fetch within the IOSurface
    ///   - host: The host to fetch from
    ///   - spanID: The span ID to use for this operation
    /// - Returns: Decrypted private data in IOSurfaces
    package func fetch(
        identifier: String,
        range: ClosedRange<Int>?,
        host: String,
        spanID: UInt64
    ) async throws -> IOSurface {
        let interval = self.signposter.beginInterval("EW.fetch2.signpost")
        defer {
            self.signposter.endInterval("EW.fetch2.signpost", interval)
        }
        do {
            return try await self.ensembleWardenMetrics.reportingClientMetrics(
                operationName: "fetch2") {
                let (session, requestID) = try self.getSession()
                return try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
                    try await PrismTracing.withSpan(name: "EnsembleWardenFetch2") {
                        return try await self.doFetch2(identifier: identifier, range: range, host: host, session: session)
                    }
                }
            }
        } catch {
            logger.error("""
                Fetch2 failed. \
                error=\(String(reportable: error), privacy: .public) \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
            throw error
        }
    }

    private func doFetch2(
        identifier: String,
        range: ClosedRange<Int>?,
        host: String,
        session: XPCSession
    ) async throws -> IOSurface {
        logger.debug("""
            Fetching IOSurface from ensemblewardend (new API). \
            ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
            request_id=\(PrismTracing.requestID, privacy: .public) \
            span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
            """)

        let request = EnsembleWardenDaemonXPC.Fetch2(
            identifier: identifier,
            range: range,
            host: host,
            requestID: PrismTracing.requestID,
            spanID: PrismTracing.spanID)

        let response = try await session.sendXPC(request: request)
        let ioSurface: IOSurface
        switch response {
        case .success(let returned): ioSurface = returned
        case .failure(let error): throw error
        }
        try ioSurface.takeOwnership()
        return ioSurface
    }

    /// Fetch IOSurface metadata associated with the specified identifier
    /// and decrypt it so it can be used by the caller.
    /// This function uses EnsembleTransport as the backend.
    /// - Parameters:
    ///   - identifier: A string identifying the metadata to fetch
    ///   - host: The host to fetch from
    ///   - spanID: The span ID to use for this operation
    /// - Returns: The metadata associated with the key or nil if no metadata
    /// was published
    package func fetchMetadata(
        identifier: String,
        host: String,
        spanID: UInt64
    ) async throws -> IOSurface? {
        let interval = self.signposter.beginInterval(
            "EW.fetchMetadata.signpost")
        defer {
            self.signposter.endInterval(
                "EW.fetchMetadata.signpost", interval)
        }
        do {
            return try await self.ensembleWardenMetrics.reportingClientMetrics(
                operationName: "fetchMetadata") {
                let (session, requestID) = try self.getSession()
                return try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
                    try await PrismTracing.withSpan(name: "EnsembleWardenFetchMetadata") {
                        return try await self.doFetchMetadata(identifier: identifier, host: host, session: session)
                    }
                }
            }
        } catch {
            logger.error("""
                FetchMetadata failed. \
                error=\(String(reportable: error), privacy: .public) \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
            throw error
        }
    }

    private func doFetchMetadata(
        identifier: String,
        host: String,
        session: XPCSession
    ) async throws -> IOSurface? {
        logger.debug("""
            Fetching IOSurface metadata from ensemblewardend (new API). \
            ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
            request_id=\(PrismTracing.requestID, privacy: .public) \
            span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
            """)

        let request = EnsembleWardenDaemonXPC.FetchMetadata(
            identifier: identifier,
            host: host,
            requestID: PrismTracing.requestID,
            spanID: PrismTracing.spanID)

        let response = try await session.sendXPC(request: request)
        let ioSurface: IOSurface?
        switch response {
            case .success(let returned): ioSurface = returned
            case .failure(let error): throw error
        }
        try ioSurface?.takeOwnership()
        return ioSurface
    }

    package func delete(
        identifier: String,
        spanID: UInt64
    ) async throws {
        return try await self.delete(
            identifier: identifier, host: nil, spanID: spanID)
    }

    package func delete(
        identifier: String,
        host: String,
        spanID: UInt64
    ) async throws {
        return try await self.delete(
            identifier: identifier, host: Optional(host), spanID: spanID)
    }

    private func delete(
        identifier: String,
        host: String?,
        spanID: UInt64
    ) async throws {
        let interval = self.signposter.beginInterval(
            "EW.delete.signpost")
        defer {
            self.signposter.endInterval(
                "EW.delete.signpost", interval)
        }
        do {
            return try await self.ensembleWardenMetrics.reportingClientMetrics(
                operationName: "delete") {
                let (session, requestID) = try self.getSession()
                return try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
                    try await PrismTracing.withSpan(name: "EnsembleWardenDeleteClient") {
                        logger.log("""
                        Deleting IOSurface from ensemblewardend (new API). \
                        ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                        request_id=\(requestID, privacy: .public) \
                        span_id=\(spanID.hexEncoded, privacy: .public)
                        """)

                        let request = EnsembleWardenDaemonXPC.Delete(
                            identifier: identifier,
                            host: host,
                            requestID: requestID,
                            spanID: spanID)

                        let response = try await session.sendXPC(
                            request: request)
                        switch response {
                        case .success(_): break
                        case .failure(let error): throw error
                        }
                    }
                }
            }
        } catch {
            logger.error("""
                Delete failed. \
                error=\(String(reportable: error), privacy: .public) \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
            throw error
        }
    }
    private func getSession() throws -> (XPCSession, UUID) {
        return try self.state.withLock { state in
            switch state {
            case .notYetConnected, .prewarmed(_), .sendingCryptoHandles:
                throw EnsembleWardenError.keyIDNotSupplied
            case .ready(let session, let requestID):
                return (session, requestID)
            case .noLongerValid:
                throw EnsembleWardenError.clientNoLongerActive
            }
        }
    }
}

fileprivate extension EnsembleWardenDaemonXPC.TransferPurpose {
    init(purpose: KVCacheTransferPurpose) {
        switch purpose {
        case .ftET:
            self = .ftET
        }
    }
}
