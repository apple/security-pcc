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

import CFPreferenceCoder
import CloudAttestation
import CloudBoardAttestationDAPI
import CloudBoardCommon
import CloudBoardIdentity
import CloudBoardLogging
import CloudBoardMetrics
import Foundation
import MobileGestaltPrivate
import NIOCore
import os

/// Long-lived daemon responsible for managing the periodically rotated SEP-backed node key, providing a corresponding
/// attestation bundle to cloudboardd, and providing a key reference to cb_jobhelper instances to allow it to derive
/// session keys for the end-to-end encrypted communication with the client.
package actor CloudBoardAttestationDaemon {
    public static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CloudBoardAttestationDaemon"
    )

    private static let metricsClientName = "cb_attestationd"

    private let apiServer: CloudBoardAttestationAPIServerProtocol
    private let config: CloudBoardAttestationDConfiguration
    // we have no need to mock out the clock at the level of the daemon
    private let clock = ContinuousClock()

    private let metrics: MetricsSystem

    public init(
        apiServer: CloudBoardAttestationAPIServerProtocol = CloudBoardAttestationAPIXPCServer.localListener(),
        configPath: String? = nil,
        metrics: MetricsSystem? = nil
    ) throws {
        self.apiServer = apiServer

        var config: CloudBoardAttestationDConfiguration = if let configPath {
            try CloudBoardAttestationDConfiguration.fromFile(path: configPath, secureConfigLoader: .real)
        } else {
            try CloudBoardAttestationDConfiguration.fromPreferences()
        }
        let configJSON = try String(decoding: JSONEncoder().encode(config), as: UTF8.self)
        Self.logger.log("Loaded configuration: \(configJSON, privacy: .public)")
        try config.validate()
        self.config = config

        self.metrics = metrics ?? CloudMetricsSystem(clientName: Self.metricsClientName)
    }

    internal init(
        apiServer: CloudBoardAttestationAPIServerProtocol,
        config: CloudBoardAttestationDConfiguration,
        metrics: MetricsSystem
    ) {
        self.apiServer = apiServer
        self.config = config
        self.metrics = metrics
    }

    private func makeAttestationBundleCache(
        customSearchPath: CustomSearchPathDirectory
    ) throws -> any AttestationBundleCache {
        do {
            let cacheDirectory: URL = try customSearchPath.lookup(for: .cachesDirectory, in: .userDomainMask)
                .appending(component: CFPreferences.cbAttestationPreferencesDomain)
            return try OnDiskAttestationBundleCache(directoryURL: cacheDirectory)
        } catch {
            Self.logger.error(
                "Failed to initialize on disk attestation bundle cache with error: \(error, privacy: .public) Falling back to noop cache."
            )
            return NoopAttestationBundleCache()
        }
    }

    /// An ensemble loses all state when it reboots, and any prior degree of trust associated with it having been used
    /// before. Therefore in many cases when we refer to "an ensemble" we are really referring to "an ensemble which has
    /// not rebooted".
    /// On first boot cb_attestationd creates a UUID(bootId) and writes it to a file on disk. On subsequent restarts it
    /// reads the bootId from this file.
    /// cb_attestationd inserts this into our attestations each time as a piece of application data.
    /// We also advertise this to ROPES through service discovery.
    internal func loadBootID(customSearchPath: CustomSearchPathDirectory) -> String? {
        var bootID = nil as String?
        do {
            let cacheDirectory: URL = try customSearchPath.lookup(for: .cachesDirectory, in: .userDomainMask)
                .appending(component: CFPreferences.cbAttestationPreferencesDomain)

            let fileManager: FileManager = .init()
            do {
                // Ensure cache directory exists and create missing parent directories if needed.
                // If the directory already exists, the function succeeds without error.
                try fileManager.createDirectory(
                    at: cacheDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                Self.logger
                    .error("Failed to create cache directory, error: \(String(unredacted: error), privacy: .public)")
                return nil
            }

            let bootIdFileURL = cacheDirectory.appending(component: "boot-id")
            if fileManager.fileExists(atPath: bootIdFileURL.path()) {
                do {
                    bootID = try Data(contentsOf: bootIdFileURL, options: .uncached).utf8String
                    if let bootID {
                        Self.logger.log("Loaded bootId: \(bootID) from the on disk file: \(bootIdFileURL)")
                    } else {
                        Self.logger.error("Failed to decode bootId from disk file as UTF8 string: \(bootIdFileURL)")
                    }
                } catch {
                    Self.logger
                        .error(
                            "Unable to read file \(bootIdFileURL) to load bootId, error: \(String(unredacted: error), privacy: .public)"
                        )
                }
            } else {
                // File doesn't exist. Create bootId and write to file on disk.
                bootID = Self.generateTimeOrderedBootID()
                if fileManager.createFile(atPath: bootIdFileURL.path(), contents: bootID?.data) {
                    if let bootID {
                        Self.logger.log("Written bootId: \(bootID) to the on disk file: \(bootIdFileURL)")
                    }
                } else {
                    Self.logger
                        .error("Unable to write bootId: \(bootID ?? "nil") to the on disk file: \(bootIdFileURL)")
                    bootID = nil
                }
            }
        } catch {
            Self.logger
                .error("Unable to load bootId for ensemble node, error: \(String(unredacted: error), privacy: .public)")
        }
        return bootID
    }

    /// Generates a time-ordered bootID that allows chronological comparison
    /// Format: {ISO-8601-basic-format-timestamp-with-milliseconds}-{random-uuid}
    /// Example: 20231114T160530.123Z-550e8400-e29b-41d4-a716-446655440000
    /// Uses ISO 8601 basic format (no colons or dashes in time/date) to be compatible with EnsembleInstanceId
    /// which uses ':' as a delimiter in its serialization format.
    /// This enables ROPES to determine the most recent bootID when multiple Service Discovery
    /// updates arrive with the same endpoint but different bootIDs.
    /// - Parameter date: Defaults to the current date. Needed for testing.
    internal static func generateTimeOrderedBootID(date: Date = Date.now) -> String {
        let formatter = ISO8601DateFormatter()
        // Use basic format: remove colon and dash separators
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.formatOptions.subtract(.withColonSeparatorInTime)
        formatter.formatOptions.subtract(.withDashSeparatorInDate)
        let timestamp = formatter.string(from: date)
        let randomUUID = UUID().uuidString
        return "\(timestamp)-\(randomUUID)"
    }

    /// The means to make and validate attestations
    /// This is fundamentally different depending on whether we are doing proper Customer validatable
    /// SEP backed attestation or the in memory keys that allow testing
    private func makeAttestationFunctionality(
        nodeInfo: NodeInfo,
        bootID: String?
    ) throws -> (provider: any AttestationProviderProtocol, validatorFactory: any AttestationValidatorFactoryProtocol) {
        if self.config.useInMemoryKey {
            let attestationProvider = InMemoryKeyAttestationProvider(
                // Leave this simple until someone has a use case to test it using in memory keys
                // By simply agreeing it everywhere any tests using the proxy paths relying on this
                // "just working" will not have to do anything
                releaseDigest: CloudBoardAttestation.neverKnownReleaseDigest,
                ensembleID: self.config.testEnsembleID,
                bootID: self.config.testBootID,
                rackID: self.config.testRackID
            )
            return (attestationProvider, InMemoryAttestationValidatorFactory())
        } else {
            let attestationProvider = CloudAttestationProvider(
                configuration: self.config,
                metrics: self.metrics,
                releaseDigestExpiryGracePeriod: self.config.transparencyLog.releaseDigestExpiryGracePeriodMinutes,
                nodeInfo: nodeInfo,
                bootID: bootID
            )
            return (attestationProvider, CloudAttestationValidatorFactory())
        }
    }

    private func makeReleasesProvider() throws -> (any ReleasesProviderProtocol, IdentityManager?)? {
        guard self.config.isProxy else {
            return nil
        }
        if let releasesOverride = self.config.transparencyLog.proxiedReleaseDigestsOverride {
            Self.logger.log("Creating releases provider from configuration")
            return (InMemoryReleasesProvider(releases: releasesOverride), nil)
        } else if self.config.cloudAttestation.includeTransparencyLogInclusionProof {
            Self.logger.log("Creating releases provider from Transparency Log")
            let identityManager: IdentityManager = .init(
                useSelfSignedCert: false,
                metricsSystem: self.metrics,
                metricProcess: "cb_attestationd"
            )
            return (TransparencyLogReleasesProvider(
                transparencyLog: SWTransparencyLog(
                    environment: CloudAttestation.Environment.default,
                    identityManager: identityManager,
                    metadataApplicationNames: self.config.transparencyLog
                        .transparencyLogMetadataApplications,
                    retryConfig: self.config.transparencyLog.transparencyLogRetryConfiguration,
                    metrics: self.metrics
                ),
                releaseDigestsPollingIntervalMinutes: self.config.transparencyLog
                    .releaseDigestPollingIntervalMintues,
                pollingIntervalJitter: self.config.transparencyLog.pollingIntervalJitter
            ), identityManager)
        } else {
            return nil
        }
    }

    public func start(
        customSearchPath: CustomSearchPathDirectory
    ) async throws {
        Self.logger.log("Starting")
        switch customSearchPath {
        case .systemNormal:
            () // do nothing
        case .fromPreferences:
            configureTemporaryDirectory(suffix: CFPreferences.cbAttestationPreferencesDomain, logger: Self.logger)
        case .explicit:
            Self.logger.log("using an explicit custom search path")
            if self.config.secureConfig.shouldEnforceAppleInfrastructureSecurityConfig {
                fatalError("Attempt to set explicit search paths which should only be used for testing")
            }
        }

        let nodeInfo = NodeInfo.load(secureConfig: self.config.secureConfig)
        if let isLeader = nodeInfo.isLeader {
            if !isLeader {
                Self.logger.log("Not a leader node. Exiting.")
                Foundation.exit(0)
            }
        } else {
            Self.logger.error("Unable to check if node is a leader. Continuing.")
        }
        // only start emitting metrics if we are a leader node
        try await CloudBoardMetrics.Uptime.withStandardMetrics(
            processInfo: Metrics.ProcessInfo.self,
            metrics: self.metrics
        ) {
            try await self._start(customSearchPath: customSearchPath, nodeInfo: nodeInfo)
        }
    }

    private func _start(
        customSearchPath: CustomSearchPathDirectory,
        nodeInfo: NodeInfo
    ) async throws {
        let bootID = self.loadBootID(customSearchPath: customSearchPath)
        do {
            let attestationBundleCache = try self.makeAttestationBundleCache(customSearchPath: customSearchPath)
            let (attestationProvider, attestationValidatorFactory) = try self
                .makeAttestationFunctionality(nodeInfo: nodeInfo, bootID: bootID)
            let releasesProviderResult = try self.makeReleasesProvider()

            try await withThrowingTaskGroup(of: Void.self) { group in
                if let (releasesProvider, identityManager) = releasesProviderResult {
                    group.addTask {
                        try await releasesProvider.run()
                    }
                    group.addTask {
                        if let identityManager {
                            await identityManager.identityUpdateLoop()
                        }
                    }
                }

                group.addTask {
                    try await CloudBoardAttestationServer(
                        apiServer: self.apiServer,
                        attestationProvider: attestationProvider,
                        attestationValidatorFactory: attestationValidatorFactory,
                        releasesProvider: releasesProviderResult?.0,
                        enableReleaseSetValidation: self.config.enableReleaseSetValidation,
                        keyLifetime: self.config.keyLifetime,
                        keyExpiryGracePeriod: self.config.keyExpiryGracePeriod,
                        metrics: self.metrics,
                        attestationCache: attestationBundleCache,
                        existingAttestationsAvailableOnlyOnNodeAfterReleaseEntryAddition: self.config.isProxy && self
                            .config
                            .existingAttestationsAvailableOnlyOnNodeAfterReleaseEntryAddition,
                        maximumValidatedEntryCacheSize: self.config.maximumValidatedEntryCacheSize,
                        isProxy: self.config.isProxy,
                        clock: self.clock,
                        workerRackIDCacheTTL: self.config.rackIdCacheLifetime
                    ).run()
                }

                group.addTask {
                    try await runEmitMemoryUsageMetricsLoop(
                        logger: Self.logger,
                        metricsSystem: self.metrics,
                        physicalMemoryFootprintGauge: {
                            Metrics.CloudBoardAttestationDaemon.PhysicalMemoryFootprintGauge(value: $0)
                        },
                        lifetimeMaxPhysicalMemoryFootprintGauge: {
                            Metrics.CloudBoardAttestationDaemon.LifetimeMaxPhysicalMemoryFootprintGauge(value: $0)
                        }
                    )
                }

                try await _ = group.next()
                group.cancelAll()
            }
        } catch {
            Self.logger.error("fatal error, exiting: \(String(unredacted: error), privacy: .public)")
            throw error
        }

        /// Workaround to prevent Swift compiler from ignoring all conformances defined in Logging+ReportableError
        /// rdar://126351696 (Swift compiler seems to ignore protocol conformances not used in the same target)
        _ = CloudAttestationProviderError.cloudAttestationUnavailable.publicDescription
    }
}

enum CloudBoardAttestationError: Error {
    case keyLifetimeTooLong
    /// An error that can occur when validating an attestation
    /// when it is checked by CloudBoard rather than the CloudAttestation framework.
    /// This could occur in testing paths, but also where we cache the validation of an attestation
    /// which may eventually expire
    case attestationExpired
}

extension CloudBoardAttestationDConfiguration {
    mutating func validate() throws {
        let totalKeyLifetime = self.keyLifetime + self.keyExpiryGracePeriod
        if totalKeyLifetime > .hours(48) {
            CloudBoardAttestationDaemon.logger.error(
                "Configured key lifetime plus grace period of \(totalKeyLifetime.nanoseconds / 1_000_000_000, privacy: .public) seconds exceeds maximum of 48 hours"
            )
            throw CloudBoardAttestationError.keyLifetimeTooLong
        }
    }
}

extension CloudBoardAttestationDaemon {
    static func forTesting(
        apiServer: CloudBoardAttestationAPIServerProtocol,
        config: CloudBoardAttestationDConfiguration,
        metrics: MetricsSystem
    ) -> CloudBoardAttestationDaemon {
        return .init(apiServer: apiServer, config: config, metrics: metrics)
    }
}

extension ExponentialBackoffStrategy {
    init(from config: CloudBoardAttestationDConfiguration.RetryConfiguration) {
        self = .init(
            initialDelay: config.initialDelay,
            multiplier: config.multiplier,
            maxDelay: config.maxDelay,
            jitterPercent: config.jitter
        )
    }
}
