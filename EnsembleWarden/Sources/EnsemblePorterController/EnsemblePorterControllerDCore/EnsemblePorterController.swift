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

//
//  EnsemblePorterController.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 15/09/2025.
//

#if canImport(AppleComputeEnsembler)
@_weakLinked package import AppleComputeEnsembler
#endif
private import AppServerSupport.OSLaunchdJob
package import EnsemblePorter
package import EnsemblePorterCommon
private import EnsemblePorterProtos
package import Foundation
private import InternalSwiftProtobuf
internal import OSLog
package import Synchronization
private import System
@preconcurrency private import XPC
private import XPCPrivate

extension EnsemblePorterController {
    package enum Mode: Sendable {
#if canImport(AppleComputeEnsembler)
        case production(transponder: EnsembledTransponder, factory: LaunchDProcessCreation)
#endif
        case test(transponder: MockEnsembleTransponder, factory: TestProcessCreation)

#if canImport(AppleComputeEnsembler)
        package static func production(
            maxPorterInstances: Int = EnsemblePorterConstants.maxPorterInstances
        ) throws -> Self {
            let metrics = EnsemblePorterMetrics()
            return .production(
                transponder: try EnsembledTransponder(),
                factory: .init(metrics: metrics, maxInstances: maxPorterInstances)
            )
        }
#endif

        package static func test() -> Self {
            return .test(
                transponder: MockEnsembleTransponder(),
                factory: TestProcessCreation()
            )
        }
    }
}

/// EnsemblePorterController runs on the followers and has the job of starting EnsemblePorters.
///
/// On the leader EnsemblePorter is started by cb_jobhelper. This doesn't exist on the followers.
/// We therefore need a long-lived daemon that will spawn the per-process ensembleporters whenever
/// the leader sends a specific message to the followers.
/// This is the job of EnsemblePorterController.
package final class EnsemblePorterController: Sendable {

    private let metrics: EnsemblePorterMetrics
    private let mode: Mode
    private let logger = Logger(subsystem: EnsemblePorterConstants.controllerLoggerSubsystem,
                                category: "EnsemblePorterController")

    private let messagesReceivedCount: Mutex<Int> = .init(0)
    /// Allows us to be able to wait for `n` messages to have been received.
    private let waitingForMessagesContinuations: Mutex<[Int: CheckedContinuation<Void, Never>]> = .init([:])

    /// Per-instance last heartbeat time. Key is instance UUID.
    private let lastHeartbeatTimes: Mutex<[UUID: ContinuousClock.Instant]> = .init([:])

    /// How long the controller waits without a heartbeat before removing an instance.
    private let heartbeatTimeoutDuration: Duration

    /// How often the controller checks for timed-out instances.
    private let heartbeatCheckInterval: Duration

    package init(mode: EnsemblePorterController.Mode, metrics: EnsemblePorterMetrics = .init(),
                 heartbeatTimeoutDuration: Duration = EnsemblePorterConstants.heartbeatTimeoutDuration,
                 heartbeatCheckInterval: Duration = EnsemblePorterConstants.heartbeatSendInterval) {
        self.metrics = metrics
        self.mode = mode
        self.heartbeatTimeoutDuration = heartbeatTimeoutDuration
        self.heartbeatCheckInterval = heartbeatCheckInterval
    }

    /// Wait for the controller to have received at least the specified number of messages.
    ///
    /// Used for testing.
    internal func waitForMessages(_ count: Int) async {
        await withCheckedContinuation { continuation in
            self.waitingForMessagesContinuations.withLock { waiters in
                let currentCount = self.messagesReceivedCount.withLock { $0 }
                if currentCount >= count {
                    continuation.resume()
                } else {
                    waiters[count] = continuation
                }
            }
        }
    }

    package func run() async throws {
        self.logger.log("Hello from ensembleportercontroller")
        await EnsemblePorterControllerWatchdogService().activate()

        switch self.mode {
#if canImport(AppleComputeEnsembler)
        case .production(let transponder, _):
            try await transponder.registerMessageHandler(appID: EnsemblePorterConstants.ensembledAppID, handler: self.handleIncomingMessage)
#endif
        case .test(let transponder, _):
            try await transponder.registerMessageHandler(appID: EnsemblePorterConstants.ensembledAppID, handler: self.handleIncomingMessage)
        }

        defer { self.metrics.controllerActiveJobs.set(0) }

        while !Task.isCancelled {
            try await Task.sleep(for: self.heartbeatCheckInterval)
            await self.removeTimedOutInstances()
            do {
                let count: Int
                switch self.mode {
#if canImport(AppleComputeEnsembler)
                case .production(_, let factory):
                    count = try factory.runningInstanceCount()
#endif
                case .test(_, let factory):
                    count = try factory.runningInstanceCount()
                }
                self.metrics.controllerActiveJobs.set(Int64(count))
            } catch {
                self.logger.error("Failed to query active job count: \(String(reportable: error), privacy: .public)")
            }
        }
    }

    internal func handleIncomingMessage(rank: Int, data: Data) async throws -> Data {
        self.logger.trace("New message received")

        // Increment message count and notify waiters
        let currentCount = self.messagesReceivedCount.withLock { count in
            count += 1
            return count
        }

        // Check if any waiters are waiting for this count
        self.waitingForMessagesContinuations.withLock { waiters in
            var toResume: [CheckedContinuation<Void, Never>] = []
            for (waitingCount, continuation) in waiters {
                if currentCount >= waitingCount {
                    toResume.append(continuation)
                    waiters.removeValue(forKey: waitingCount)
                }
            }
            for continuation in toResume {
                continuation.resume()
            }
        }

        do {
            let response = try await self.handle(message: data)
            self.logger.trace("Handled message successfully")
            return response
        } catch EnsemblePorterError.invalidMessageReceived {
            self.logger.error("Invalid message received.")
            self.metrics.invalidMessagesReceived.increment()
            return .init()
        } catch {
            self.logger.error("""
                Error handling message. \
                error=\(String(reportable: error), privacy: .public)
                """)
            //TODO: Better error handling
            return .init()
        }
    }

    /// Decodes a received message and uses the decoded data to create a new EnsemblePorter.
    internal func handle(message: Data) async throws -> Data {
        self.logger.trace("Handling new per-process message")
        let decodedMessage: Protos.PorterMessage
        do {
            decodedMessage = try Protos.PorterMessage(serializedBytes: message)
        } catch {
            self.logger.error("Failed to decode message as PorterMessage")
            throw EnsemblePorterError.invalidMessageReceived
        }

        let requestID = try? UUID(data: decodedMessage.requestID)
        let spanID = decodedMessage.spanID
        guard let messageType = decodedMessage.messageType else {
            self.logger.error("Received message but it did not contain a message type.")
            self.metrics.invalidMessagesReceived.increment()
            throw EnsemblePorterError.invalidMessageReceived
        }

        switch messageType {
        case .unspecified:
            self.metrics.invalidMessagesReceived.increment()
            throw EnsemblePorterError.invalidMessageReceived
        case .startNewProcess:
            self.logger.log("start new process request received on follower")
            self.metrics.startNewProcessRequests.increment()
            let instanceUUID = try await self.newProcess()
            self.logger.log("Fetching public key of ensemblefollowerporterd")
            let publicKey = try await self.getPublicKey(instanceUUID: instanceUUID)
            let proto = Protos.PorterMessage.with {
                $0.requestID = decodedMessage.requestID
                $0.spanID = decodedMessage.spanID
                $0.messageType = .startNewProcessReply(.with {
                    $0.instanceUuid = Data(uuid: instanceUUID)
                    $0.publicKey = publicKey
                })
            }
            self.logger.log("Responding to leader following startNewProcess")
            return try proto.serializedData()
        case .startNewProcessReply(_):
            self.logger.error("Received unexpected startNewProcessReply message in ensembleportercontroller.")
            self.metrics.invalidMessagesReceived.increment()
            throw EnsemblePorterError.invalidMessageReceived
        case .perProcessMessage(let perProcessMessage):
            guard let requestID else {
                throw EnsemblePorterError.invalidMessageReceived
            }
            return try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
                self.metrics.perProcessMessageRequests.increment()
                PrismTracing.logCheckpoint(name: "PerProcessMessage received on follower")
                let response = try await self.handle(perProcessMessage: perProcessMessage, requestID: requestID, spanID: spanID)
                PrismTracing.logCheckpoint(name: "Responding to leader following PerProcessMessage")
                return try response.serializedData()
            }
        case .shutdown(let shutdownRequest):
            guard let requestID else {
                throw EnsemblePorterError.invalidMessageReceived
            }
            self.metrics.shutdownRequests.increment()
            try await self.handle(shutdownRequest: shutdownRequest, requestID: requestID, spanID: spanID)
            return try Protos.EmptyMessage().serializedData()
        case .heartbeat(let heartbeat):
            let instanceUUID = try UUID(data: heartbeat.instanceUuid)
            self.logger.trace("""
                Heartbeat received. \
                instance_uuid=\(instanceUUID, privacy: .public)
                """)
            self.metrics.heartbeatMessageRequests.increment()

            let isRunning: Bool
            switch self.mode {
#if canImport(AppleComputeEnsembler)
            case .production(_, let factory):
                isRunning = factory.isInstanceRunning(instanceUUID: instanceUUID)
#endif
            case .test(_, let factory):
                isRunning = factory.isInstanceRunning(instanceUUID: instanceUUID)
            }

            self.lastHeartbeatTimes.withLock { times in
                if isRunning {
                    if times[instanceUUID] == nil {
                        self.logger.log("""
                            Adopted unknown but running instance. \
                            instance_uuid=\(instanceUUID, privacy: .public)
                            """)
                        self.metrics.instanceAdopted.increment()
                    }
                    times[instanceUUID] = ContinuousClock.now
                } else if times.removeValue(forKey: instanceUUID) != nil {
                    self.logger.warning("""
                        Heartbeat for crashed instance, removing. \
                        instance_uuid=\(instanceUUID, privacy: .public)
                        """)
                    self.metrics.instanceRemovedByProcessCrash.increment()
                } else {
                    self.logger.warning("""
                        Heartbeat for unknown/removed instance. \
                        instance_uuid=\(instanceUUID, privacy: .public)
                        """)
                }
            }

            return try Protos.HeartbeatResponse.with {
                $0.success = isRunning
            }.serializedData()
        }
    }

    private func newProcess() async throws -> UUID {
        self.logger.log("Creating new instance.")
        let uuid: UUID
        switch self.mode {
#if canImport(AppleComputeEnsembler)
        case .production(_, let factory):
            uuid = try await factory.createInstance()
#endif
        case .test(_, let factory):
            uuid = try await factory.createInstance()
        }
        self.logger.log("""
            Created new instance. \
            instance_uuid=\(uuid, privacy: .public)
            """)
        self.lastHeartbeatTimes.withLock { times in
            times[uuid] = ContinuousClock.now
        }
        return uuid
    }

    private func getPublicKey(instanceUUID: UUID) async throws -> Data {
        self.logger.log("""
            Retrieving public key from instance. \
            instance_uuid=\(instanceUUID, privacy: .public)
            """)

        let provider: EnsemblePorterCryptoProviderImpl<EnsemblePorterXPCSessionClient>
        switch self.mode {
#if canImport(AppleComputeEnsembler)
        case .production(_, let factory):
            provider = try factory.createProvider(instanceUUID: instanceUUID)
#endif
        case .test(_, let factory):
            provider = try factory.createProvider(instanceUUID: instanceUUID)
        }

        let publicKey = try await provider.getIntraEnsemblePublicKey()
        do {
            try await provider.shutdown()
        } catch {
            self.logger.warning("""
                Failed to shutdown provider after getting public key. \
                instance_uuid=\(instanceUUID, privacy: .public) \
                error=\(String(reportable: error), privacy: .public)
                """)
        }
        self.logger.log("""
            Retrieved public key from instance. \
            instance_uuid=\(instanceUUID, privacy: .public) \
            public_key_size=\(publicKey.count)
            """)
        return publicKey
    }

    private func handle(shutdownRequest: Com_Apple_Cloudos_Ensembleporter_ShutdownRequest,
                        requestID: UUID, spanID: UInt64) async throws {
        let instanceUUID = try UUID(data: shutdownRequest.instanceUuid)
        self.logger.log("""
            Shutdown request received. \
            request_id=\(requestID, privacy: .public) \
            span_id=\(spanID, privacy: .public) \
            instance_uuid=\(instanceUUID, privacy: .public)
            """)

        self.lastHeartbeatTimes.withLock { times in
            times.removeValue(forKey: instanceUUID)
        }

        switch self.mode {
#if canImport(AppleComputeEnsembler)
        case .production(_, let factory):
            try await factory.removeInstance(instanceUUID: instanceUUID)
#endif
        case .test(_, let factory):
            try await factory.removeInstance(instanceUUID: instanceUUID)
        }
        self.logger.log("""
            Successfully removed instance. \
            instance_uuid=\(instanceUUID, privacy: .public)
            """)
        self.metrics.instanceRemovedByShutdown.increment()
    }

    /// Reaps porter instances that should no longer be running.
    ///
    /// Iterates the launchd-running set as the source of truth and removes:
    /// - Instances we have no record of (orphans left behind by a previous controller
    ///   life — these are invisible to our in-memory bookkeeping).
    /// - Instances whose last heartbeat is older than ``heartbeatTimeoutDuration``.
    ///
    /// Also drops bookkeeping entries for instances launchd no longer knows about, so
    /// ``lastHeartbeatTimes`` can't grow unbounded.
    private func removeTimedOutInstances() async {
        let now = ContinuousClock.now
        let runningUUIDs: Set<UUID>
        do {
            switch self.mode {
#if canImport(AppleComputeEnsembler)
            case .production(_, let factory):
                runningUUIDs = Set(try factory.runningInstances())
#endif
            case .test(_, let factory):
                runningUUIDs = Set(try factory.runningInstances())
            }
        } catch {
            self.metrics.runningInstancesQueryFailures.increment()
            self.logger.error("""
                Failed to query running instances. \
                error=\(String(reportable: error), privacy: .public)
                """)
            return
        }

        let toReap: [(uuid: UUID, reason: String)] = self.lastHeartbeatTimes.withLock { times in
            // Drop bookkeeping entries for instances launchd no longer has.
            for uuid in times.keys where !runningUUIDs.contains(uuid) {
                times.removeValue(forKey: uuid)
            }
            return runningUUIDs.compactMap { uuid in
                if let last = times[uuid] {
                    return now - last > self.heartbeatTimeoutDuration
                        ? (uuid, "stale_heartbeat")
                        : nil
                }
                return (uuid, "orphan")
            }
        }

        for (uuid, reason) in toReap {
            self.logger.log("""
                Reaping instance. \
                instance_uuid=\(uuid, privacy: .public) \
                reason=\(reason, privacy: .public)
                """)

            do {
                switch self.mode {
#if canImport(AppleComputeEnsembler)
                case .production(_, let factory):
                    try await factory.removeInstance(instanceUUID: uuid)
#endif
                case .test(_, let factory):
                    try await factory.removeInstance(instanceUUID: uuid)
                }
                self.lastHeartbeatTimes.withLock { $0.removeValue(forKey: uuid) }
                self.logger.log("""
                    Successfully reaped instance. \
                    instance_uuid=\(uuid, privacy: .public) \
                    reason=\(reason, privacy: .public)
                    """)
                switch reason {
                case "orphan":
                    self.metrics.instanceRemovedByOrphan.increment()
                default:
                    self.metrics.instanceRemovedByHeartbeatTimeout.increment()
                }
            } catch {
                self.logger.error("""
                    Failed to reap instance. \
                    instance_uuid=\(uuid, privacy: .public) \
                    reason=\(reason, privacy: .public) \
                    error=\(String(reportable: error), privacy: .public)
                    """)
            }
        }
    }

    private func handle(perProcessMessage: Protos.PerProcessMessage,
                        requestID: UUID, spanID: UInt64) async throws -> Protos.EmptyMessage {
        let instanceUUID = try UUID(data: perProcessMessage.instanceUuid)
        self.logger.log("""
            Providing encrypted turn-keys to provider. \
            request_id=\(requestID, privacy: .public) \
            span_id=\(spanID, privacy: .public)
            """)
        switch self.mode {
#if canImport(AppleComputeEnsembler)
        case .production(_, let factory):
            let provider = try factory.createProvider(instanceUUID: instanceUUID)
            try await provider.provide(encryptedCryptoMaterial: perProcessMessage.serialisedMessage,
                                       leaderPublicKey: perProcessMessage.leaderPublicKey,
                                       requestID: requestID, spanID: spanID)
#endif
        case .test(_, let factory):
            let provider = try factory.createProvider(instanceUUID: instanceUUID)
            try await provider.provide(encryptedCryptoMaterial: perProcessMessage.serialisedMessage,
                                       leaderPublicKey: perProcessMessage.leaderPublicKey,
                                       requestID: requestID, spanID: spanID)
        }
        return .init()
    }
}

extension Data {
    init(uuid: UUID) {
        self = Swift.withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }
}
