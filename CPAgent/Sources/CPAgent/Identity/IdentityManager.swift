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

import AsyncHTTPClient
import Configuration
import CPAgentMetrics
import Crypto
import Foundation
import Logging
import Metrics
import NIO
import NIOCore
import NIOHTTP1
import NIOSSL
import Narrative
import SwiftASN1
import X509

public struct IdentityManager: Sendable {
    struct ResolvedIdentity: Sendable {
        var chain: [Certificate]
        var privateKey: Certificate.PrivateKey
    }

    struct GenericAccount: Account {
        let serializedName: String
    }

    struct GenericDomain: Domain {
        let name: String
        let certificateType: CertificateType
    }

    enum IdentityManagerError: Error, Equatable {
        case certificateNotAvailable
        case unableToRunSecureService
        case unableToCreateIdentity
        case unableToParseChainCert(String)
        case unimplementedFunctionality
        case updateLoopNotStarted
    }

    enum IdentityKind: String {
        case narrative
        case selfSigned
    }

    private let logger = Logger(label: "CPAgent.IdentityManager")
    private let identityDir: String
    private let identityPrefix: String
    private let identityKind: IdentityKind
    private let renewalBufferFraction: Double

    private static let minimumRenewalBuffer: TimeInterval = 60

    init(cpagentConfiguration: CPAgentMeasuredConfiguration) {
        self.identityDir = cpagentConfiguration.identityDir
        self.identityKind = cpagentConfiguration.identityKind
        self.identityPrefix = cpagentConfiguration.identityPrefix
        self.renewalBufferFraction = cpagentConfiguration.identityRenewalBufferFraction
    }

    public func provisionIdentity() async throws -> Date {
        let certificate: Certificate
        switch identityKind {
        case .narrative:
            certificate = try await provisionNarrativeIdentity()
        case .selfSigned:
            certificate = try generateSelfSignedCert()
        }
        return nextRenewalDate(after: certificate)
    }

    /// Computes when `certificate` should be renewed, based on `renewalBufferFraction` of its own
    /// lifetime, so the timing scales automatically if the issued validity period ever changes.
    func nextRenewalDate(after certificate: Certificate) -> Date {
        let lifetime = certificate.notValidAfter.timeIntervalSince(certificate.notValidBefore)
        let buffer = max(lifetime * renewalBufferFraction, Self.minimumRenewalBuffer)
        return certificate.notValidAfter.addingTimeInterval(-buffer)
    }

    /// Records the narrative certificate's expiry as a gauge holding the absolute expiry time
    /// (Unix epoch seconds), so alerting can compute the time remaining and catch certificates
    /// that are about to lapse. Recording an absolute timestamp rather than a remaining-seconds
    /// snapshot means the value stays meaningful even if a later provisioning attempt fails.
    private func recordNarrativeExpiry(_ certificate: Certificate) {
        Gauge(label: "\(MetricLabel.narrativeCertificateExpiryEpoch)")
            .record(certificate.notValidAfter.timeIntervalSince1970)
    }

    private func exportIdentity(
        privateKey: Certificate.PrivateKey,
        certificateChain: [Certificate],
        toDirectory directory: String
    ) throws {
        let fileManager = FileManager.default
        let directoryURL = URL(fileURLWithPath: directory)

        logger.info(
            "Exporting identity to filepath.",
            metadata: [
                "directory": "\(directory)", "prefix": "\(identityPrefix)",
            ]
        )

        // Create identity directory if it doesn't exist
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Export leaf certificate
        if let leafCert = certificateChain.first {
            let certURL = directoryURL.appendingPathComponent(
                "\(identityPrefix)-cert.pem")
            let certPEM = try leafCert.serializeAsPEM()
            try certPEM.pemString.write(to: certURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: certURL.path)
        }

        // Export full certificate chain
        let fullChainURL = directoryURL.appendingPathComponent(
            "\(identityPrefix)-fullchain.pem")
        let fullChainPEM = try certificateChain.map { try $0.serializeAsPEM().pemString }.joined(
            separator: "\n")
        try fullChainPEM.write(to: fullChainURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fullChainURL.path)

        // Export private key
        let privKeyURL = directoryURL.appendingPathComponent(
            "\(identityPrefix)-privkey.pem")
        let privKeyPEM = try privateKey.serializeAsPEM()
        let privKeyData = Data(privKeyPEM.pemString.utf8)

        // We need to make the private key (and certs) world-readable, because these will be read by processes in other
        // containers potentially run as different users
        // TODO: rdar://170082028 ([Mirkwood] Don't run containerised processes as root)
        guard
            fileManager.createFile(
                atPath: privKeyURL.path,
                contents: privKeyData,
                attributes: [.posixPermissions: 0o644]
            )
        else {
            throw IdentityManagerError.unableToCreateIdentity
        }
    }

    private func fetchNarrativeIdentity() async throws -> Certificate {
        try await MetricsSystem.withStatusMetrics(labelPrefix: MetricLabel.fetchIdentityRequest) {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }
            do {
                logger.info("Retrieving gcp instance identity.")
                let (gcpIdentity, gcpInstanceName) = try await Identity.inferredGcpInstanceIdentity(
                    httpClient: httpClient)

                logger.info(
                    "Received gcp instance identity, now transitioning to platform identity.")

                let platformIdentity = try await gcpIdentity.transition(
                    httpClient: httpClient,
                    httpQueryTimeout: .seconds(10),
                    account: GenericAccount(serializedName: gcpInstanceName),
                    domain: GenericDomain(name: "gcp", certificateType: .platform)
                )

                logger.info("Received platform identity, now transitioning to host identity.")

                let hostIdentity = try await platformIdentity.transition(
                    httpClient: httpClient,
                    httpQueryTimeout: .seconds(10),
                    account: GenericAccount(serializedName: gcpInstanceName),
                    domain: GenericDomain(name: "gcp", certificateType: .host)
                )

                guard
                    let (privateKey, certificateChain) = hostIdentity.privateKeyAndCertificateChain,
                    let leafCertificate = certificateChain.first
                else {
                    throw IdentityManagerError.unableToParseChainCert(
                        "Narrative transition returned not certificate")
                }

                logger.info("Exporting host identity to disk.")
                try self.exportIdentity(
                    privateKey: privateKey,
                    certificateChain: certificateChain,
                    toDirectory: identityDir)
                recordNarrativeExpiry(leafCertificate)
                return leafCertificate
            } catch {
                logger.error(
                    "Failed to obtain platform identity.",
                    metadata: ["error": "\(String(reportable: error))"])
                throw error
            }
        }
    }

    internal func generateSelfSignedCert() throws -> Certificate {
        logger.info(
            "Generating self-signed certificate and saving to disk.",
            metadata: ["directory": "\(identityDir)"])
        let selfSignedIdentity = try SelfSignedIdentity(commonName: "Apple Host Identity")
            .makeResolvedIdentity()

        guard let leafCertificate = selfSignedIdentity.chain.first else {
            throw IdentityManagerError.unableToParseChainCert(
                "Self-signed identity did not produce a certificate")
        }

        // Export using exportIdentity
        try exportIdentity(
            privateKey: selfSignedIdentity.privateKey,
            certificateChain: selfSignedIdentity.chain,
            toDirectory: identityDir
        )

        logger.info(
            "Successfully generated self-signed certificate",
            metadata: [
                "directory": "\(identityDir)",
                "prefix": "\(identityPrefix)",
            ])

        return leafCertificate
    }

    /// Provisions identity for the CPAgent by fetching the Narrative actor identity
    /// and saving the certs and private key to identity directory set by CPAgentMeasuredConfiguration.
    private func provisionNarrativeIdentity() async throws -> Certificate {
        while true {
            do {
                let certificate = try await self.fetchNarrativeIdentity()
                logger.info(
                    "Successfully fetched identity and saved to disk."
                )
                return certificate
            } catch {
                logger.error(
                    "Failed to fetch identities. Waiting for 10 seconds before retrying to fetch identities.",
                    metadata: ["error": "\(String(reportable: error))"]
                )
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}
