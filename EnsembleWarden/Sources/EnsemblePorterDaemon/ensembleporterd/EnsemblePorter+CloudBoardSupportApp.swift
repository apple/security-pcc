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
//  EnsemblePorter+CloudBoardSupportApp.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 2025-09-12.
//

#if canImport(CloudBoardJobSupport)
@_weakLinked private import CloudBoardJobSupport
#endif

private import EnsemblePorterCommon
private import EnsemblePorterDCore
private import Foundation
private import OSLog

#if canImport(CloudBoardJobSupport)

@main
extension EnsemblePorter: CloudBoardSupportApp {

    private static let logger = Logger(subsystem: EnsemblePorterConstants.loggerSubsystem, category: "EnsemblePorterSupportApp")

    convenience init() {
        do {
            let config = try EnsemblePorterSecureConfigLoader.real.load()
            Self.logger.log("""
                Loaded SecureConfig. \
                security_policy=\(String(describing: config.securityPolicy), privacy: .public) \
                heartbeat_send_interval=\(config.heartbeatSendInterval, privacy: .public) \
                heartbeat_timeout_duration=\(config.heartbeatTimeoutDuration, privacy: .public) \
                heartbeat_send_timeout=\(config.heartbeatSendTimeout, privacy: .public) \
                max_consecutive_heartbeat_failures=\(config.maxConsecutiveHeartbeatFailures, privacy: .public)
                """)
            try self.init(
                clientType: .defaultClient,
                maxConsecutiveHeartbeatFailures: config.maxConsecutiveHeartbeatFailures,
                heartbeatSendInterval: config.heartbeatSendInterval,
                heartbeatSendTimeout: config.heartbeatSendTimeout
            )
        } catch {
            Self.logger.error("Top-level error thrown. error=\(String(reportable: error), privacy: .public)")
            fatalError("Unexpected top level error: \(error)")
        }
    }

    public func warmup() async throws {
        Self.logger.log("EnsemblePorter warmup starting")
        try await self.prewarmFollowers()
        Self.logger.log("EnsemblePorter warmup completed")
    }

    public func teardown() async throws {
        Self.logger.log("EnsemblePorter teardown starting")
        try await self.teardownFollowers()
        Self.logger.log("EnsemblePorter teardown completed")
    }

    fileprivate func run(environment: CloudBoardSupportAppEnvironment) async throws {
        Self.logger.log("EnsemblePorterSupportApp start.")
        defer {
            Self.logger.log("EnsemblePorterSupportApp end.")
        }

        let keyDerivationHelper = environment.keyDerivation
        let cloudBoardStream = try await environment.cryptoMaterial.registerForCryptoMaterialUpdates()
        let (materialStream, continuation) = AsyncStream<Data>.makeStream()

        try await withThrowingTaskGroup(of: Bool.self) { group in
            // Task to map CloudBoard stream to Data stream
            group.addTask {
                Self.logger.log("CloudBoard stream task started")
                defer {
                    continuation.finish()
                    Self.logger.log("CloudBoard stream task ended")
                }
                for await material in cloudBoardStream {
                    continuation.yield(material.material)
                }
                return false  // Stream task is not the run task
            }

            group.addTask {
                Self.logger.log("Crypto material updates task started.")
                defer {
                    Self.logger.log("Crypto material updates task ended")
                }

                // Derive the FT/ET key immediately
                let derivedKey = try await keyDerivationHelper.deriveKey(
                    purpose: "ft-et-key",
                    outputByteCount: 32
                )

                guard let requestID = UUID(uuidString: environment.plaintextMetadata.requestID) else {
                    throw EnsemblePorterError.missingRequestID
                }
                let spanID = environment.traceContext.spanID

                try await self.orchestrateCryptoMaterialCoordination(
                    derivedKey: derivedKey.key,
                    requestID: requestID,
                    spanID: spanID,
                    cryptoMaterials: materialStream
                )
                return false  // Orchestration task is not the run task
            }

            group.addTask {
                Self.logger.log("Running ensembleporter.")
                defer {
                    Self.logger.log("Finished running ensembleporter.")
                }
                try await self.run()
                return true  // This is the run task - its completion should trigger exit
            }

            // Wait for the EnsemblePorter run task to complete.
            // The orchestration task completes when keys are ready, but we must NOT
            // exit until the run task finishes - otherwise we cancel EnsemblePorter mid-request.
            while let isRunTask = try await group.next() {
                if isRunTask {
                    break  // Run task completed, exit the support app
                }
                // Other tasks (stream, orchestration) completed - keep waiting for run task
            }
            group.cancelAll()
        }
    }
}

#else

@main
extension EnsemblePorter {
    static func main() {
        print("Built without CloudBoardJobSupport")
    }
}

#endif
