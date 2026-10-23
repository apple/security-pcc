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

import CloudAttestationV2
import CloudBoardProtos
import CloudBoardUtilities
import Configuration
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import GRPCServiceLifecycle
import Logging
import Metrics
import PrivateCloudCompute
import ServiceLifecycle

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The main server for cb_attestationd.
///
/// Manages attestation key generation and exposes the AttestationProvider gRPC
/// service for cloudboardd to subscribe to attestation set updates.
package struct CloudBoardAttestationServer: Sendable {
    private static let logger = Logger(label: "cb_attestationd.CloudBoardAttestationServer")

    private let attestedConfigReader: ConfigReader
    private let unattestedConfigReader: ConfigReader
    private let keyManager: AttestedKeyManager

    package init(
        attestedConfigReader: ConfigReader,
        unattestedConfigReader: ConfigReader
    ) {
        self.attestedConfigReader = attestedConfigReader
        self.unattestedConfigReader = unattestedConfigReader
        self.keyManager = AttestedKeyManager()
    }

    package func run(otelServices: [Service] = []) async throws {
        let statusMonitor = AttestationDaemonStatusMonitor(
            initial: .initializing(phase: "starting key backend")
        )

        let backendType = self.attestedConfigReader.string(
            forKey: "attestation.backend",
            default: "default"
        )
        let kpsSocketPath = self.attestedConfigReader.string(
            forKey: "attestation.kps_socket_path",
            default: "/run/container_launcher/kmaserver.sock"
        )
        let attestationSocketPath = self.attestedConfigReader.string(
            forKey: "attestation.attestation_socket_path",
            default: "/run/container_launcher/teeserver.sock"
        )

        let simKpsSocketPath = self.attestedConfigReader.string(
            forKey: "attestation.simulated_kps_socket_path",
            default: "/run/sim_container_launcher/kmaserver.sock"
        )
        let simAttestationSocketPath = self.attestedConfigReader.string(
            forKey: "attestation.simulated_attestation_socket_path",
            default: "/run/sim_container_launcher/teeserver.sock"
        )

        let backend: any KeyBackend
        switch backendType {
        case "simulator":
            Self.logger.info(
                "Using WSD simulator key backend (forced)",
                metadata: [
                    "kpsSocketPath": "\(simKpsSocketPath)",
                    "attestationSocketPath": "\(simAttestationSocketPath)",
                ]
            )
            backend = WSDSimulatorBackend(
                kpsSocketPath: simKpsSocketPath,
                attestationSocketPath: simAttestationSocketPath
            )
        case "wsd":
            Self.logger.info("Using real WSD key backend (forced)")
            backend = DefaultKeyBackend()
        default:
            // Auto-detect: if both WSD sockets already exist, use the real WSD;
            // otherwise fall back to the simulator.
            if Self.socketExists(atPath: kpsSocketPath) && Self.socketExists(atPath: attestationSocketPath) {
                Self.logger.info(
                    "Auto-detected WSD sockets, using real WSD key backend",
                    metadata: [
                        "kpsSocketPath": "\(kpsSocketPath)",
                        "attestationSocketPath": "\(attestationSocketPath)",
                    ]
                )
                backend = DefaultKeyBackend()
            } else {
                Self.logger.info(
                    "WSD sockets not found, falling back to simulator key backend",
                    metadata: [
                        "kpsSocketPath": "\(simKpsSocketPath)",
                        "attestationSocketPath": "\(simAttestationSocketPath)",
                    ]
                )
                backend = WSDSimulatorBackend(
                    kpsSocketPath: simKpsSocketPath,
                    attestationSocketPath: simAttestationSocketPath
                )
            }
        }

        // Start the backend and generate the initial attested key.
        // If this fails (e.g. /run/container_launcher is not available), log the
        // error but continue running in degraded mode — the gRPC service will
        // wait for a key to be generated before streaming attestation updates.
        let appData = try self.buildAppData()
        let attestedKeyConfiguration = AttestedKeyConfiguration(
            attestedConfigReader: self.attestedConfigReader,
            unattestedConfigReader: self.unattestedConfigReader,
            appData: appData
        )

        let platformCertPath: String? =
            if self.unattestedConfigReader.bool(forKey: "attestation.platform_cert.wait", default: false) {
                self.unattestedConfigReader.string(
                    forKey: "attestation.platform_cert.path",
                    default: "/var/run/cloudattestation/platformcertificate.pem"
                )
            } else {
                nil
            }

        let attestationService = AttestationGRPCService(
            keyManager: self.keyManager,
            statusMonitor: statusMonitor
        )

        let udsPath = self.unattestedConfigReader.string(
            forKey: "attestation.grpc.uds",
            default: "/var/run/cb-attestationd/cb-attestationd.sock"
        )

        Self.logger.info(
            "Starting attestation gRPC server",
            metadata: ["uds": "\(udsPath)"]
        )

        let udsServer = GRPCServer(
            transport: .http2NIOPosix(
                address: .unixDomainSocket(path: udsPath),
                transportSecurity: .plaintext
            ),
            services: [attestationService]
        )

        let rotationService = KeyRotationService(
            keyManager: self.keyManager,
            statusMonitor: statusMonitor,
            backend: backend,
            platformCertPath: platformCertPath,
            attestedKeyConfiguration: attestedKeyConfiguration
        )

        let services: [any Service] = otelServices + [udsServer, rotationService]
        let serviceGroup = ServiceGroup(
            services: services,
            gracefulShutdownSignals: [.sigint, .sigterm],
            logger: Logger(label: "cb_attestationd.service-lifecycle")
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            // Once the socket is bound, relax its permissions so cloudboardd can connect() even when running as a
            // different user
            group.addTask {
                do {
                    _ = try await udsServer.transport.listeningAddress
                    try FileManager.default.setAttributes([.posixPermissions: 0o766], ofItemAtPath: udsPath)
                    Self.logger.info("Relaxed attestation socket permissions", metadata: ["path": "\(udsPath)"])
                } catch is CancellationError {
                    // Graceful shutdown
                } catch {
                    Self.logger.error(
                        "Failed to relax attestation socket permissions",
                        metadata: ["path": "\(udsPath)", "error": "\(String(reportable: error))"]
                    )
                    throw error
                }
            }

            try await group.waitForAll()
        }
    }

    /// Run with a custom gRPC transport, primarily for in-memory testing.
    func run<Transport: ServerTransport>(
        transport: Transport,
        keyStore: any CloudAttestationV2.KeyStore
    ) async throws {
        let appData = try self.buildAppData()
        let attestedKeyConfiguration = AttestedKeyConfiguration(
            attestedConfigReader: self.attestedConfigReader,
            unattestedConfigReader: self.unattestedConfigReader,
            appData: appData
        )
        try await self.keyManager.generateKey(using: keyStore, configuration: attestedKeyConfiguration)

        let statusMonitor = AttestationDaemonStatusMonitor(initial: .ready)
        let attestationService = AttestationGRPCService(
            keyManager: self.keyManager,
            statusMonitor: statusMonitor
        )

        let server = GRPCServer(
            transport: transport,
            services: [attestationService]
        )

        try await server.serve()
    }

    /// Check if a Unix domain socket exists at the given path using stat(2).
    ///
    /// Returns `true` only if the path exists and is a socket (`S_IFSOCK`).
    static func socketExists(atPath path: String) -> Bool {
        var statBuf = stat()
        guard stat(path, &statBuf) == 0 else { return false }
        return (statBuf.st_mode & S_IFMT) == S_IFSOCK
    }

    /// Build serialized `PrivateCloudCompute_AppData` containing compute node metadata used for enforcing reuse
    /// constraints on proxy nodes.
    private func buildAppData() throws -> Data {
        let ensembleID = self.unattestedConfigReader.string(forKey: "FLEET_NODE_ID")
        let bootID: String?
        do {
            bootID = try readSystemBootIdentifier()
        } catch {
            Self.logger.error(
                "Failed to read system boot identifier. Omitting from attestation app data.",
                metadata: ["error": "\(String(unredacted: error))"]
            )
            bootID = nil
        }

        Self.logger.info(
            "Attestation app data",
            metadata: [
                "ensembleID": "\(ensembleID ?? "<not configured>")",
                "bootID": "\(bootID ?? "<not determined>")",
            ]
        )

        let attestationAppData = Proto_Attestation_AttestationAppData.with {
            $0.rackID = Data("rack_not_relevant".utf8)
            if let ensembleID {
                $0.ensembleID = Data(ensembleID.utf8)
            }
            if let bootID {
                $0.bootID = Data(bootID.utf8)
            }
        }

        let appDataProto = try PrivateCloudCompute_AppData.with {
            $0.version = 1
            $0.domain = "com.apple.PrivateCloudCompute"
            $0.name = "Compute Node"
            $0.metadata = try .init(message: attestationAppData)
        }

        return try appDataProto.serializedData()
    }
}

extension AttestedKeyConfiguration {
    /// Hard upper bound on the real lifetime of an attested key, i.e. `advertisedKeyLifetime + keyLifetimeGracePeriod`.
    ///
    /// The grace period is additive (see `AttestedKeyManager.generateKey`), so this bounds the total time
    /// key material can exist in WSD. A configured lifetime whose sum with the grace period exceeds this is
    /// clamped down to it (see the config-reader initializer below).
    static let maxAdvertisedKeyLifetime: Duration = .seconds(48 * 60 * 60)

    /// Fallback lifetime used when the configured lifetime is not a positive value.
    static let defaultAdvertisedKeyLifetime: Duration = .seconds(60 * 60 * 24)

    init(attestedConfigReader: ConfigReader, unattestedConfigReader: ConfigReader, appData: Data?) {
        let logger = Logger(label: "cb_attestationd.AttestedKeyConfiguration")

        // A non-positive lifetime would produce keys that expire immediately; fall back to the default.
        let rawKeyLifetimeSeconds = attestedConfigReader.int(
            forKey: "attestation.key.lifetimeSeconds",
            default: 60 * 60 * 24
        )
        let configuredKeyLifetime: Duration
        if rawKeyLifetimeSeconds > 0 {
            configuredKeyLifetime = .seconds(rawKeyLifetimeSeconds)
        } else {
            logger.warning(
                "Configured attested key lifetime is not positive. Falling back to the default.",
                metadata: [
                    "rawKeyLifetimeSeconds": "\(rawKeyLifetimeSeconds)",
                    "defaultAdvertisedKeyLifetime": "\(Self.defaultAdvertisedKeyLifetime)",
                ]
            )
            configuredKeyLifetime = Self.defaultAdvertisedKeyLifetime
        }

        // A negative grace period is meaningless; floor it at zero.
        let rawGracePeriodSeconds = attestedConfigReader.int(forKey: "attestation.key.gracePeriodSeconds", default: 5)
        let configuredGracePeriod: Duration
        if rawGracePeriodSeconds >= 0 {
            configuredGracePeriod = .seconds(rawGracePeriodSeconds)
        } else {
            logger.warning(
                "Configured attested key grace period is negative. Flooring at zero.",
                metadata: ["rawGracePeriodSeconds": "\(rawGracePeriodSeconds)"]
            )
            configuredGracePeriod = .zero
        }

        // The grace period is a short drain tail after the advertised expiry. Bound it by half the lifetime (so it
        // can't dominate a key's real life) and by half the maximum (so the max-lifetime clamp below leaves the
        // lifetime meaningfully positive rather than collapsing it to zero).
        let gracePeriodUpperBound = min(configuredKeyLifetime, Self.maxAdvertisedKeyLifetime) / 2
        let keyLifetimeGracePeriod: Duration
        if configuredGracePeriod > gracePeriodUpperBound {
            logger.warning(
                "Configured attested key grace period exceeds its upper bound. Clamping grace period.",
                metadata: [
                    "configuredGracePeriod": "\(configuredGracePeriod)",
                    "configuredKeyLifetime": "\(configuredKeyLifetime)",
                    "gracePeriodUpperBound": "\(gracePeriodUpperBound)",
                ]
            )
            keyLifetimeGracePeriod = gracePeriodUpperBound
        } else {
            keyLifetimeGracePeriod = configuredGracePeriod
        }

        // Enforce that the real key lifetime (lifetime + additive grace period) never exceeds the maximum.
        // Clamp the lifetime rather than reject, keeping the node serving under misconfiguration.
        let advertisedKeyLifetime: Duration
        if configuredKeyLifetime + keyLifetimeGracePeriod > Self.maxAdvertisedKeyLifetime {
            let clampedKeyLifetime = Self.maxAdvertisedKeyLifetime - keyLifetimeGracePeriod
            logger.warning(
                "Configured attested key lifetime plus grace period exceeds the maximum. Clamping lifetime.",
                metadata: [
                    "configuredKeyLifetime": "\(configuredKeyLifetime)",
                    "keyLifetimeGracePeriod": "\(keyLifetimeGracePeriod)",
                    "maxAdvertisedKeyLifetime": "\(Self.maxAdvertisedKeyLifetime)",
                    "clampedKeyLifetime": "\(clampedKeyLifetime)",
                ]
            )
            advertisedKeyLifetime = clampedKeyLifetime
        } else {
            advertisedKeyLifetime = configuredKeyLifetime
        }

        let retryBackoffInitialDelay = Duration.seconds(
            unattestedConfigReader.int(forKey: "attestation.key.retryBackoffInitialDelaySeconds", default: 5)
        )
        let retryBackoffMaxDelay = Duration.seconds(
            unattestedConfigReader.int(forKey: "attestation.key.retryBackoffMaxDelaySeconds", default: 5 * 60)
        )

        let environmentString = unattestedConfigReader.string(forKey: "pcc.environment", default: "dev")
        let attestationEnvironment = Environment(environmentString) ?? .dev
        let selfValidateAttestation = unattestedConfigReader.bool(forKey: "attestation.selfValidate", default: true)

        let rawCertificateLogHeadMinAgeSeconds = unattestedConfigReader.int(
            forKey: "attestation.certificateLogHeadMinAgeSeconds",
            default: 60 * 60 * 24
        )
        let certificateLogHeadMinAge: Duration
        if rawCertificateLogHeadMinAgeSeconds >= 0 {
            certificateLogHeadMinAge = .seconds(rawCertificateLogHeadMinAgeSeconds)
        } else {
            logger.warning(
                "Configured certificate transparency log head minimum age is negative. Flooring at zero.",
                metadata: [
                    "rawCertificateLogHeadMinAgeSeconds": "\(rawCertificateLogHeadMinAgeSeconds)"
                ]
            )
            certificateLogHeadMinAge = .zero
        }

        self = .init(
            attestationEnvironment: attestationEnvironment,
            appData: appData,
            selfValidateAttestation: selfValidateAttestation,
            certificateLogHeadMinAge: certificateLogHeadMinAge,
            advertisedKeyLifetime: advertisedKeyLifetime,
            keyLifetimeGracePeriod: keyLifetimeGracePeriod,
            retryBackoffInitialDelay: retryBackoffInitialDelay,
            retryBackoffMaxDelay: retryBackoffMaxDelay
        )

    }
}
