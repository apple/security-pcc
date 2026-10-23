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
//  EnsemblePorterLogic+Leader.swift
//  EnsembleWarden
//
//  Created by ORAC on 20/11/2025.
//

private import CryptoKit
private import EnsemblePorterCommon
private import EnsemblePorterProtos
package import EnsembleWardenServer
package import Foundation
private import InternalSwiftProtobuf
@_spi(OSMetric) private import os
private import OSLog
private import Synchronization

extension EnsemblePorterLogic {

    /// Provides a bunch of keys to EnsemblePorter
    ///
    /// This is called when a keyprovider (e.g. CloudBoard) has a bag of keys that it wants EnsemblePorter to take care of.
    /// They are given to us as a serialised protobuf, so that CloudBoard need not understand the structure of the data.
    ///
    /// - Parameters:
    ///   - additionalCryptoPayload: A serialised protobuf containing decrypted turn keys and FT/ET key.
    ///   - requestID: The request ID.
    ///   - spanID: The span ID.
    package func provide(additionalCryptoPayload: Data) async throws {
        PrismTracing.logCheckpoint(name: "Decoding crypto material.")

        let decodedPayload: Apple_Cloudos_Cloudllm_EnsemblePorterCryptoMaterial
        do {
            decodedPayload = try .init(serializedBytes: additionalCryptoPayload)
        } catch {
            self.metrics.incrementKeyProvision(success: false, error: .invalidKeysSupplied)
            self.logger.error("""
                Error decoding crypto material protobuf. \
                error=\(String(reportable: error), privacy: .public) \
                request_id=\(PrismTracing.requestID, privacy: .public) \
                span_id=\(PrismTracing.spanID, privacy: .public)
                """)
            throw EnsemblePorterError.invalidKeysSupplied
        }
        PrismTracing.logCheckpoint(name: "Validating turn keys")

        let keys = try decodedPayload.turnKeys.turnKeys.enumerated().map { turnNumber, encodedKey in
            let key = SymmetricKey(data: encodedKey.key)
            guard key.bitCount == SymmetricKeySize.bits256.bitCount else {
                self.metrics.incrementKeyProvision(success: false, error: .invalidKeysSupplied)
                self.logger.error("""
                    Provided key has invalid length. \
                    turn_number=\(turnNumber) \
                    request_id=\(PrismTracing.requestID, privacy: .public) \
                    span_id=\(PrismTracing.spanID, privacy: .public)
                    """)
                throw EnsemblePorterError.invalidKeysSupplied
            }
            return key
        }
        // Note: Empty turn keys is valid for non-multi-turn requests (FT/ET key only)

        // Extract FT/ET key from protobuf
        guard !decodedPayload.ftEtKey.isEmpty else {
            self.metrics.incrementKeyProvision(success: false, error: .invalidKeysSupplied)
            self.logger.error("""
                FT/ET key missing from protobuf. \
                request_id=\(PrismTracing.requestID, privacy: .public) \
                span_id=\(PrismTracing.spanID, privacy: .public)
                """)
            throw EnsemblePorterError.invalidKeysSupplied
        }
        let ftETKey = SymmetricKey(data: decodedPayload.ftEtKey)
        guard ftETKey.bitCount == SymmetricKeySize.bits256.bitCount else {
            self.metrics.incrementKeyProvision(success: false, error: .invalidKeysSupplied)
            self.logger.error("""
                FT/ET key has invalid length. \
                request_id=\(PrismTracing.requestID, privacy: .public) \
                span_id=\(PrismTracing.spanID, privacy: .public)
                """)
            throw EnsemblePorterError.invalidKeysSupplied
        }

        do {
            // Add turn keys to local keySafe first, before distributing to followers.
            // This ensures fetchFTETKey on the leader succeeds immediately after
            // crypto material arrives, rather than waiting for follower acknowledgments.
            PrismTracing.logCheckpoint(name: "Adding turn keys to key safe")
            try self.keySafe.supply(turnKeys: keys, ftETKey: ftETKey)

            try await self.sendCryptoPayloadToFollowersIfRequired(additionalCryptoPayload)
        } catch {
            self.metrics.incrementKeyProvision(success: false, error: .unexpectedError)
            throw error
        }
        self.metrics.incrementKeyProvision(success: true)
    }


    /// If the current SoC is a leader then this will distribute the additionalCryptoPayload to the followers.
    ///
    /// We send the additionalCryptoPayload in parallel to each follower and wait for a response.
    ///
    /// - Parameters:
    ///   - additionalCryptoPayload: The additional crypto payload to send to the followers. This is a serialised protobuf.
    ///   - followerTokens: The instance UUIDs of the EnsembleFollowerPorters on each of the followers.
    ///   - requestID: The request ID to use for logging.
    ///   - spanID: The span ID to use for logging.
    internal func sendCryptoPayloadToFollowersIfRequired(_ additionalCryptoPayload: Data) async throws {
        logger.log("""
            Getting ensemble node info. \
            request_id=\(PrismTracing.requestID, privacy: .public) \
            span_id=\(PrismTracing.spanID, privacy: .public)
            """)
        PrismTracing.logCheckpoint(name: "Getting ensemble node info")
        // Initialize distribution state with expected peer count
        let distributionStartTime = ContinuousClock.now
        do {
            try await withThrowingTaskGroup { group in
                for peer in self.followerInfo {
                    group.addTask {
                        try await self.sendKeysToFollower(additionalCryptoPayload: additionalCryptoPayload,
                                                          rank: peer.rank)
                    }
                }
                try await group.waitForAll()
                self.logger.log("""
                    Succesfully sent crypto payload to all followers. \
                    peer_count=\(self.followerInfo.count) \
                    request_id=\(PrismTracing.requestID, privacy: .public) \
                    span_id=\(PrismTracing.spanID, privacy: .public)
                    """)
                self.metrics.recordDistributionAttempt(success: true)
                PrismTracing.logCheckpoint(name: "Sent turn keys to all followers")
            }
            let distributionDuration = ContinuousClock.now - distributionStartTime
            self.metrics.distributionRequestDuration.set(Double(distributionDuration.components.seconds) + Double(distributionDuration.components.attoseconds) / 1e18)
        } catch {
            let distributionDuration = ContinuousClock.now - distributionStartTime
            self.metrics.distributionRequestDuration.set(Double(distributionDuration.components.seconds) + Double(distributionDuration.components.attoseconds) / 1e18)
            self.metrics.recordDistributionAttempt(success: false)
            throw error
        }
    }

    /// Performs the actual sending of the keys to a specific follower.
    ///
    /// Now pay attention... when we send keys from leader to follower we need to remember that the transport
    /// is backed by ensembled. Ensembled is not recycled per-request. By decree of SEAR it therefore cannot
    /// have access to keys. We therefore encrypt the additionalCryptoPayload using a keypair between
    /// EnsemblePorter and EnsembleFollowerPorter.
    ///
    /// This is achieved by us having received a public key from ensemblefollowerporter when we started it on
    /// the followers. We use this to do a asymmetric key exchange, encrypt the additionalCryptoPayload, and
    /// then send the result.
    ///
    /// - Parameters:
    ///   - additionalCryptoPayload: The additional crypto payload to send to the follower.
    ///   - rank: The rank of the follower to send the keys to.
    ///   - requestID: The request identifier used to correlate this send operation with any potential...
    ///   - spanID: The span ID to use for logging.
    private func sendKeysToFollower(additionalCryptoPayload: Data, rank: Int) async throws {
        try await PrismTracing.withSpan(name: "Sending turn keys to peer") {
            PrismTracing.logCheckpoint(name: "Leader encrypting additionalCryptoPayload for follower")
            guard let peerInfo = self.followerInfo.first(where: { $0.rank == rank }) else {
                throw EnsemblePorterError.transportFailed

            }
            let encryptedPayload: Data
            do {
                let sealedBox = try AES.GCM.seal(additionalCryptoPayload, using: peerInfo.intraEnsembleKey)
                encryptedPayload = sealedBox.combined!
            } catch {
                self.logger.error("""
                    Failed to encrypt crypto payload for follower. \
                    peer=\(rank) \
                    error=\(String(reportable: error), privacy: .public) \
                    request_id=\(PrismTracing.requestID, privacy: .public) \
                    span_id=\(PrismTracing.spanID, privacy: .public)
                    """)
                throw error
            }

            let perProcessMessage = Protos.PorterMessage.with {
                $0.requestID = Data(uuid: PrismTracing.requestID)
                $0.spanID = PrismTracing.spanID
                $0.messageType = .perProcessMessage(.with {
                    $0.instanceUuid = Data(uuid: peerInfo.instanceUUID)
                    $0.serialisedMessage = encryptedPayload
                    $0.leaderPublicKey = peerInfo.intraEnsemblePublicKey.rawRepresentation
                })
            }
            PrismTracing.logCheckpoint(name: "Sending encrypted additionalCryptoPayload to peer")
            let sendStart = ContinuousClock.now
            do {
                _ = try await self.intraEnsembleTransponder.sendData(appID: EnsemblePorterConstants.ensembledAppID,
                                                                     data: perProcessMessage.serializedData(),
                                                                     destination: rank,
                                                                     timeout: 0.25)
                let elapsed = ContinuousClock.now - sendStart
                self.metrics.recordFollowerSend(
                    rank: rank,
                    success: true,
                    durationSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            } catch {
                let elapsed = ContinuousClock.now - sendStart
                self.metrics.recordFollowerSend(
                    rank: rank,
                    success: false,
                    durationSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                throw error
            }
            PrismTracing.logCheckpoint(name: "Response received from peer")
        }
    }

    /// Fetches the instance UUIDs for ensemblefollowerporter running on each of the followers.
    package func fetchEnsembleFollowerPorterInstanceUUIDs() async throws -> FollowerTokens {
        // This method should only be called on the leader node
        let nodeInfo = try await self.intraEnsembleTransponder.nodeInfo()
        guard nodeInfo.leader else {
            self.logger.error("""
                fetchEnsembleFollowerPorterInstanceUUIDs called on a follower node. \
                request_id=\(PrismTracing.requestID, privacy: .public) \
                span_id=\(PrismTracing.spanID, privacy: .public)
                """)
            throw EnsemblePorterError.notLeader
        }

        self.followerTokensFetched.withLock { fetched in
            // TODO: Should this throw?
            if fetched {
                self.logger.warning("""
                    EnsembleFollowerPorter instance UUIDs have already been fetched. \
                    follower_instance_count=\(self.followerInfo.count) \
                    request_id=\(PrismTracing.requestID, privacy: .public) \
                    span_id=\(PrismTracing.spanID, privacy: .public)
                    """)
            }
            fetched = true
        }

        self.logger.log("""
            Fetched EnsembleFollowerPorter instance UUIDs. \
            follower_instance_count=\(self.followerInfo.count) \
            request_id=\(PrismTracing.requestID, privacy: .public) \
            span_id=\(PrismTracing.spanID, privacy: .public)
            """)

        let tokens = Dictionary(uniqueKeysWithValues: self.followerInfo.map { ($0.rank, $0.instanceUUID) })
        return FollowerTokens(tokens: tokens)
    }

    /// Sends shutdown requests to all followers and waits for completion.
    ///
    /// This method sends shutdown requests to all followers in parallel using a task group.
    /// Each follower receives a shutdown message containing their instance UUID, and the method
    /// waits for responses from all followers to ensure they have begun their shutdown process.
    package func shutdownAllFollowers() async throws {
        guard !self.followerInfo.isEmpty else {
            self.logger.log("""
                No followers to shutdown. \
                request_id=\(PrismTracing.requestID, privacy: .public) \
                span_id=\(PrismTracing.spanID, privacy: .public)
                """)
            return
        }

        self.logger.log("""
            Shutting down all followers. \
            follower_count=\(self.followerInfo.count) \
            request_id=\(PrismTracing.requestID, privacy: .public) \
            span_id=\(PrismTracing.spanID, privacy: .public)
            """)

        try await withThrowingTaskGroup { group in
            for follower in self.followerInfo {
                group.addTask {
                    try await self.sendShutdownToFollower(rank: follower.rank, instanceUUID: follower.instanceUUID)
                }
            }
            try await group.waitForAll()
        }

        self.logger.log("""
            Successfully sent shutdown requests to all followers. \
            follower_count=\(self.followerInfo.count) \
            request_id=\(PrismTracing.requestID, privacy: .public) \
            span_id=\(PrismTracing.spanID, privacy: .public)
            """)
    }

    /// Sends a shutdown request to a specific follower.
    ///
    /// - Parameters:
    ///   - rank: The rank of the follower to shut down.
    ///   - instanceUUID: The instance UUID of the follower's EnsembleFollowerPorter.
    private func sendShutdownToFollower(rank: Int, instanceUUID: UUID) async throws {
        self.logger.log("""
            Sending shutdown request to follower. \
            rank=\(rank) \
            instance_uuid=\(instanceUUID, privacy: .public) \
            request_id=\(PrismTracing.requestID, privacy: .public) \
            span_id=\(PrismTracing.spanID, privacy: .public)
            """)

        let shutdownMessage = Protos.PorterMessage.with {
            $0.requestID = Data(uuid: PrismTracing.requestID)
            $0.spanID = PrismTracing.spanID
            $0.messageType = .shutdown(.with {
                $0.instanceUuid = Data(uuid: instanceUUID)
            })
        }

        let sendStart = ContinuousClock.now
        do {
            _ = try await self.intraEnsembleTransponder.sendData(
                appID: EnsemblePorterConstants.ensembledAppID,
                data: shutdownMessage.serializedData(),
                destination: rank,
                timeout: 1.0)

            let elapsed = ContinuousClock.now - sendStart
            self.metrics.recordFollowerSend(
                rank: rank,
                success: true,
                durationSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            self.logger.log("""
                Shutdown request sent successfully to follower. \
                rank=\(rank) \
                request_id=\(PrismTracing.requestID, privacy: .public) \
                span_id=\(PrismTracing.spanID, privacy: .public)
                """)
        } catch {
            let elapsed = ContinuousClock.now - sendStart
            self.metrics.recordFollowerSend(
                rank: rank,
                success: false,
                durationSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            self.logger.error("""
                Failed to send shutdown request to follower. \
                rank=\(rank) \
                error=\(String(reportable: error), privacy: .public) \
                request_id=\(PrismTracing.requestID, privacy: .public) \
                span_id=\(PrismTracing.spanID, privacy: .public)
                """)
            throw error
        }
    }

}
