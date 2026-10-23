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
//  PCC+ProxyNodeAttestor.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import InternalSwiftProtobuf
import os.log

extension PCC {
    public struct ProxyNodeAttestor: Attestor {
        static let logger: Logger = Logger(subsystem: "com.apple.CloudAttestation", category: "PCC.ProxyNodeAttestor")

        public var attestingKey: SecKey {
            get throws {
                try inner.attestingKey
            }
        }

        /// An array of SHA256 digests of releases this proxy handles.
        public let proxiedReleases: [Data]

        @_spi(Private)
        public var inner: NodeAttestor

        @_spi(Private)
        public var assetProvider: any AttestationAssetProvider {
            get {
                self.inner.assetProvider
            }
            set {
                self.inner.assetProvider = newValue
            }
        }

        @_spi(Private)
        public var transparencyProver: TransparencyProver

        @_spi(Private)
        public var certificateTransparency: Bool

        @_spi(Private)
        public var certificateTransparencyFetchFailClosed: Bool

        @_spi(Private)
        public var certificateTransparencyShouldRecycleProxyAttestation: Bool

        @_spi(Private)
        public var sepProtocol: any SEP.AttestationProtocol {
            get {
                self.inner.sepProtocol
            }
            set {
                self.inner.sepProtocol = newValue
            }
        }

        @_spi(Private)
        public var transitiveReleaseTransparency = false

        /// Creates a new ``ProxyNodeAttestor`` using transitive release transparency.
        public init() {
            self = .init(transparencyProver: SWTransparencyLog(environment: Environment.current))
        }

        /// Creates a new ``ProxyNodeAttestor`` using transitive release transparency.
        /// - Parameter transparencyProver: A transparency prover to use.
        public init(transparencyProver: TransparencyProver) {
            self = .init(transparencyProver: transparencyProver, assetProvider: PCC.AssetProvider(), environment: Environment.current)
        }

        /// Creates a new ``ProxyNodeAttestor``.
        /// - Parameter proxiedReleases: An array of SHA256 digests of releases this proxy handles.
        @available(*, deprecated, renamed: "init()", message: "use the initializer without proxiedReleases")
        public init(proxiedReleases: [Data]) {
            self.inner = NodeAttestor()
            self.proxiedReleases = proxiedReleases
            self.transparencyProver = self.inner.transparencyProver

            let configuration = Configuration(for: Environment.current)
            self.certificateTransparency = configuration.certificateTransparency
            self.certificateTransparencyFetchFailClosed = configuration.certificateTransparencyFetchFailClosed
            self.certificateTransparencyShouldRecycleProxyAttestation = configuration.certificateTransparencyShouldRecycleProxyAttestation
        }

        /// Creates a new ``ProxyNodeAttestor``.
        /// - Parameter proxiedReleases: An array of SHA256 digests of releases this proxy handles.
        /// - Parameter transparencyProver: A transparency prover to use.
        @available(*, deprecated, renamed: "init(transparencyProver:)", message: "use the initializer without proxiedReleases")
        public init(proxiedReleases: [Data], transparencyProver: some TransparencyProver) {
            self.inner = NodeAttestor(transparencyProver: transparencyProver)
            self.proxiedReleases = proxiedReleases
            self.transparencyProver = self.inner.transparencyProver

            let configuration = Configuration(for: Environment.current)
            self.certificateTransparency = configuration.certificateTransparency
            self.certificateTransparencyFetchFailClosed = configuration.certificateTransparencyFetchFailClosed
            self.certificateTransparencyShouldRecycleProxyAttestation = configuration.certificateTransparencyShouldRecycleProxyAttestation
        }

        /// Creates a new ``ProxyNodeAttestor``.
        /// - Parameter proxiedReleases: An array of SHA256 digests of releases this proxy handles.
        /// - Parameter transparencyProver: A transparency prover to use.
        /// - Parameter assetProvider: An asset providerto use.
        /// - Parameter environment: The environment for the attestation.
        @_spi(Private)
        @available(*, deprecated, renamed: "init(transparencyProver:assetProvider:environment:)", message: "use the initializer without proxiedReleases")
        public init(proxiedReleases: [Data], transparencyProver: some TransparencyProver, assetProvider: some AttestationAssetProvider, environment: Environment) {
            self.inner = NodeAttestor(transparencyProver: transparencyProver, assetProvider: assetProvider, environment: environment)
            self.proxiedReleases = proxiedReleases
            self.transparencyProver = transparencyProver

            let configuration = Configuration(for: Environment.current)
            self.certificateTransparency = configuration.certificateTransparency
            self.certificateTransparencyFetchFailClosed = configuration.certificateTransparencyFetchFailClosed
            self.certificateTransparencyShouldRecycleProxyAttestation = configuration.certificateTransparencyShouldRecycleProxyAttestation
        }

        /// Creates a new ``ProxyNodeAttestor`` using transitive release transparency.
        /// - Parameter transparencyProver: A transparency prover to use.
        /// - Parameter assetProvider: An asset providerto use.
        /// - Parameter environment: The environment for the attestation.
        @_spi(Private)
        public init(transparencyProver: some TransparencyProver, assetProvider: some AttestationAssetProvider, environment: Environment) {
            self.inner = NodeAttestor(transparencyProver: NopTransparencyLog(), assetProvider: assetProvider, environment: environment)
            self.transparencyProver = transparencyProver

            self.transitiveReleaseTransparency = true
            self.proxiedReleases = []

            let configuration = Configuration(for: environment)
            self.certificateTransparency = configuration.certificateTransparency
            self.certificateTransparencyFetchFailClosed = configuration.certificateTransparencyFetchFailClosed
            self.certificateTransparencyShouldRecycleProxyAttestation = configuration.certificateTransparencyShouldRecycleProxyAttestation
        }

        public func attest(key: SecKey, using attestingKey: SecKey, expiration: Date, nonce: Data?) async throws -> AttestationBundle {
            guard nonce == nil else {
                throw NodeAttestor.Error.nonceProvided
            }

            let releaseProofs: [TransparencyLogProofs]

            if transitiveReleaseTransparency {
                // When transitively verifying transparency proofs, the included release proofs aren't load bearing
                // anymore. To not break old clients we do need to provide some proofs, so we're opting to provide proofs
                // of the proxy node.
                let release = try Release.local(assetProvider: self.inner.assetProvider)
                releaseProofs = [try await transparencyProver.proveInclusion(of: Data(release.digest()), at: nil, coveringAll: .release, preferOldest: false)]
            } else {
                releaseProofs = try await transparencyProver.proveInclusion(of: proxiedReleases)
            }

            let appData = try Proto_AppData.with {
                $0.domain = "com.apple.PrivateCloudCompute"
                $0.name = "Proxy Node"
                $0.version = 1
                $0.metadata = try .init(
                    message: PrivateCloudCompute_ProxyNodeMetadata.with { metadata in
                        metadata.proxiedRelease = try releaseProofs.map { proofs in
                            try proofs.verify(expiration: expiration)
                            guard let digest = proofs.digest else {
                                throw TransparencyLogError.invalidProof
                            }

                            return PrivateCloudCompute_ProxyNodeMetadata.ProxiedRelease.with { release in
                                release.digest = digest
                                release.transparencyProofs = proofs.proto
                            }
                        }
                    }
                )
            }.serializedData()

            let nonce = Data(appData.digest())
            var bundle = try await inner.attest(key: key, using: attestingKey, expiration: expiration, nonce: nonce)
            bundle.proto.appData = appData

            if transitiveReleaseTransparency, let proofs = releaseProofs.first {
                bundle.proto.transparencyProofs = proofs.proto
            }

            // Populate Certificate Transparency proofs
            let certificateTransparencyPopulator = ProxyNodeCertificateTransparencyPopulator(
                certificateTransparency: self.certificateTransparency,
                certificateTransparencyFetchFailClosed: self.certificateTransparencyFetchFailClosed,
                transparencyProver: self.transparencyProver
            )
            try await certificateTransparencyPopulator.populateProofs(for: &bundle, expiration: expiration)

            // To ensure that trusted proxy attestations are rejected by older clients
            // without trusted proxy support, confirm that the attestation does not contain
            // the customer security policy
            try await DarwinInitPolicy(restrictedSecurityPolicies: [.customer]).evaluate(bundle: bundle)

            return bundle
        }

        public func shouldRecycle(bundle: AttestationBundle) async throws -> Bool {
            let release = Data(try Release(bundle: bundle).digest())
            Self.logger.log("Evaluating if proxy attestation should recycle, release=\(release.hexString, privacy: .public)")

            let recentProofsRelease = try await transparencyProver.proveInclusion(of: release, at: nil, coveringAll: .release, preferOldest: true)

            let recentReleaseRevision = try recentProofsRelease.proofs.inclusionProof.logRevision
            let bundleRevision = try bundle.proto.transparencyProofs.proofs.inclusionProof.logRevision

            Self.logger.log("Revisions for release: proxyNode=\(bundleRevision, privacy: .public), recentRelease=\(recentReleaseRevision, privacy: .public)")

            if recentReleaseRevision.treeID != bundleRevision.treeID {
                Self.logger.log("Recycling for tree roll (release)")
                return true
            }

            let targetRevision: UInt64

            if certificateTransparencyShouldRecycleProxyAttestation {
                let recentProofsCertificate = try await transparencyProver.proveInclusion(of: release, at: nil, coveringAll: .serverNode, preferOldest: true)
                let recentCertificateRevision = try recentProofsCertificate.proofs.inclusionProof.logRevision

                Self.logger.log("Revisions for certificate: proxyNode=\(bundleRevision, privacy: .public), recentCertificate=\(recentCertificateRevision, privacy: .public)")

                if recentCertificateRevision.treeID != bundleRevision.treeID {
                    Self.logger.log("Recycling for tree roll (certificate)")
                    return true
                }

                targetRevision = max(recentReleaseRevision.revision, recentCertificateRevision.revision)
            } else {
                targetRevision = recentReleaseRevision.revision
            }

            if targetRevision > bundleRevision.revision {
                Self.logger.log(
                    "Recycling because proxy node revision is older than target proxyNodeRevision=\(bundleRevision.revision, privacy: .public) targetRevision=\(targetRevision, privacy: .public)"
                )
                return true
            }

            Self.logger.info(
                "Proxy attestation does not need to recycle proxyNodeRevision=\(bundleRevision.revision, privacy: .public) targetRevision=\(targetRevision, privacy: .public)"
            )
            return false
        }
    }
}

extension PCC.ProxyNodeAttestor {
    struct ProxyNodeCertificateTransparencyPopulator: CertificateTransparencyPopulator {
        static let logger: Logger = Logger(subsystem: "com.apple.CloudAttestation", category: "ProxyNodeCertificateTransparencyPopulator")

        let certificateTransparency: Bool

        let certificateTransparencyFetchFailClosed: Bool

        let transparencyProver: any TransparencyProver

        func fetch(fingerprint: Data) async throws -> TransparencyLogProofs {
            try await self.transparencyProver.proveInclusion(of: fingerprint, at: nil, coveringAll: .serverNode, preferOldest: false)
        }
    }
}
