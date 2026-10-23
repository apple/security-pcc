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
import Configuration
import Crypto
import GRPCNIOTransportHTTP2
import Logging
import Metrics
import NIOCertificateReloading
import NIOSSL
import ServiceLifecycle
import SwiftASN1
import Synchronization
import X509

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The source of TLS identity, either a static resolved identity or a certificate reloader.
enum IdentitySource: Sendable {
    /// A static identity that doesn't support reloading.
    case resolved(CloudBoardIdentityManager.ResolvedIdentity)
    /// A certificate reloader that supports periodic refresh.
    case reloader(TimedCertificateReloader)
}

final class CloudBoardIdentityManager: Service {
    static let logger = Logger(label: "cloudboardd.IdentityManager")

    private enum ConfiguredBackend: Sendable {
        case backend(any IdentityBackend)
        case reloader(TimedCertificateReloader)
    }

    private enum IdentityState {
        case initialized
        case awaitingIdentity(Promise<IdentitySource, Error>)
        case identityAvailable(IdentitySource)
    }

    private let configuredBackend: ConfiguredBackend
    private let state: Mutex<IdentityState>
    private let metricsFactory: any MetricsFactory

    init(
        attestedConfigReader: ConfigReader,
        unattestedConfigReader: ConfigReader,
        backendOverride: (any IdentityBackend)? = nil,
        metricsFactory: any MetricsFactory = MetricsSystem.factory
    ) {
        self.metricsFactory = metricsFactory
        if let backendOverride {
            self.configuredBackend = .backend(backendOverride)
        } else {
            let backendType = attestedConfigReader.string(
                forKey: "identity.backend",
                as: CloudBoardIdentityBackend.self,
                default: .filesystem
            )

            switch backendType {
            case .selfsigned:
                Self.logger.warning("Using self-signed identity backend without certificate reloading")
                self.configuredBackend = .backend(SelfSignedBackend())

            case .filesystem:
                Self.logger.info("Using file system-based identity backend with certificate reloading")
                let directoryPath = attestedConfigReader.string(
                    forKey: "identity.filesystem.path",
                    default: "/var/run/narrative/certs"
                )
                let fullchainFilename = attestedConfigReader.string(
                    forKey: "identity.filesystem.fullchainfile",
                    default: "host-identity-fullchain.pem"
                )
                let privateKeyFilename = attestedConfigReader.string(
                    forKey: "identity.filesystem.privatekeyfile",
                    default: "host-identity-privkey.pem"
                )
                let refreshInterval = Duration.seconds(
                    unattestedConfigReader.int(
                        forKey: "identity.filesystem.refreshintervalseconds",
                        default: 300
                    )
                )

                let certificatePath = URL(fileURLWithPath: directoryPath)
                    .appendingPathComponent(fullchainFilename).path
                let privateKeyPath = URL(fileURLWithPath: directoryPath)
                    .appendingPathComponent(privateKeyFilename).path

                self.configuredBackend = .reloader(
                    TimedCertificateReloader(
                        refreshInterval: refreshInterval,
                        certificateSource: .init(location: .file(path: certificatePath), format: .pem),
                        privateKeySource: .init(location: .file(path: privateKeyPath), format: .pem),
                        logger: Self.logger
                    )
                )
            }
        }

        self.state = Mutex(.initialized)
    }

    private enum IdentityAction {
        case initialize(Promise<IdentitySource, Error>)
        case await(Future<IdentitySource, Error>)
        case `return`(IdentitySource)
    }

    /// The identity source for TLS configuration.
    var identitySource: IdentitySource {
        get async throws {
            let action: IdentityAction = self.state.withLock { state in
                switch state {
                case .initialized:
                    let promise = Promise<IdentitySource, Error>()
                    state = .awaitingIdentity(promise)
                    return .initialize(promise)
                case .awaitingIdentity(let promise):
                    return .await(Future(promise))
                case .identityAvailable(let source):
                    return .return(source)
                }
            }

            switch action {
            case .initialize(let promise):
                do {
                    let source = try await self.initializeIdentitySource()
                    self.state.withLock { state in
                        state = .identityAvailable(source)
                    }
                    promise.succeed(with: source)
                    return source
                } catch {
                    Self.logger.error(
                        "Failed to initialize identity",
                        metadata: [
                            "error": "\(String(unredacted: error))"
                        ]
                    )
                    promise.fail(with: error)
                    throw error
                }
            case .await(let future):
                return try await future.value
            case .return(let source):
                return source
            }
        }
    }

    private func initializeIdentitySource() async throws -> IdentitySource {
        switch self.configuredBackend {
        case .backend(let backend):
            Self.logger.info("Fetching identity from backend")
            let identity = try await backend.fetchIdentity()
            Self.logger.info("Successfully fetched identity")
            return .resolved(identity)

        case .reloader(let reloader):
            Self.logger.info("Loading initial certificates from file system")
            // Wait for certificate files to become available before returning
            while true {
                do {
                    try reloader.reload()
                    return .reloader(reloader)
                } catch let error as TimedCertificateReloader.Error {
                    Self.logger.warning(
                        "Failed to load certificate files, waiting before retrying",
                        metadata: [
                            "error": "\(error.description))"
                        ]
                    )
                } catch {
                    Self.logger.warning(
                        "Failed to load certificate files, waiting before retrying",
                        metadata: [
                            "error": "\(String(reportable: error))"
                        ]
                    )
                }
                Counter(label: "cloudboard_certificate_reload_retry_total", factory: self.metricsFactory).increment()
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    func run() async throws {
        // Fetch identity early to fail fast if there's an issue
        _ = try await self.identitySource

        switch self.configuredBackend {
        case .reloader(let reloader):
            // Run the reloader for periodic certificate refresh
            try await reloader.run()

        case .backend:
            // No reloading needed, just wait for cancellation
            do {
                while true {
                    try await Task.sleep(nanoseconds: .max)
                }
            } catch is CancellationError {
                Self.logger.info("CloudBoardIdentityManager.run cancelled")
            }
        }
    }

    struct ResolvedIdentity: Sendable {
        var chain: [Certificate]
        var privateKey: Certificate.PrivateKey
    }
}

extension CloudBoardIdentityManager: IdentityCertificateExpiryProvider {
    /// The `notValidAfter` of the leaf (first) certificate in the current identity chain.
    ///
    /// For the reloader backend this reflects the most recently reloaded certificate. Returns `nil` if no leaf
    /// certificate is currently available (e.g. the reloader hasn't loaded one yet).
    func currentLeafCertificateExpiry() async throws -> Date? {
        switch try await self.identitySource {
        case .resolved(let identity):
            return identity.chain.first?.notValidAfter
        case .reloader(let reloader):
            guard
                let leaf = reloader.sslContextConfigurationOverride.certificateChain?.first,
                case .certificate(let certificate) = leaf
            else {
                return nil
            }
            // `NIOSSLCertificate.notValidAfter` is expressed in seconds since the UNIX epoch.
            return Date(timeIntervalSince1970: TimeInterval(certificate.notValidAfter))
        }
    }
}

enum CloudBoardIdentityBackend: String, Hashable, Sendable {
    case filesystem
    case selfsigned
}

enum IdentityManagerError: Error, Equatable {
    case certificateNotAvailable
    case unableToRunSecureService
    case unableToCreateIdentity
    case unableToParseChainCert(String)
    case unimplementedFunctionality
    case updateLoopNotStarted
}

extension IdentityManagerError: ReportableError {
    var publicDescription: String {
        switch self {
        case .certificateNotAvailable: "IdentityManagerError.certificateNotAvailable"
        case .unableToRunSecureService: "IdentityManagerError.unableToRunSecureService"
        case .unableToCreateIdentity: "IdentityManagerError.unableToCreateIdentity"
        case .unableToParseChainCert: "IdentityManagerError.unableToParseChainCert"
        case .unimplementedFunctionality: "IdentityManagerError.unimplementedFunctionality"
        case .updateLoopNotStarted: "IdentityManagerError.updateLoopNotStarted"
        }
    }
}

protocol IdentityBackend: Sendable {
    func fetchIdentity() async throws -> CloudBoardIdentityManager.ResolvedIdentity
}

extension [TLSConfig.CertificateSource] {
    init(_ certificates: [Certificate]) throws {
        self = try certificates.map {
            var serializer = DER.Serializer()
            try serializer.serialize($0)
            let derBytes = serializer.serializedBytes
            return TLSConfig.CertificateSource.bytes(derBytes, format: .der)
        }
    }
}

extension TLSConfig.PrivateKeySource {
    static func bytes(_ privateKey: Certificate.PrivateKey) throws -> TLSConfig.PrivateKeySource {
        TLSConfig.PrivateKeySource.bytes(try privateKey.serializeAsPEM().derBytes, format: .der)
    }
}
