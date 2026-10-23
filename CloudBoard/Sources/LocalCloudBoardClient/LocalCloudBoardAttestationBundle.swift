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

internal import CloudAttestation
@_spi(HPKEAlgID) import CryptoKit
import Foundation
internal import HTTPClientStateMachine
internal import InternalSwiftProtobuf
import os

public struct LocalCloudBoardAttestationBundle: Sendable {
    fileprivate static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "LocalCloudBoardClient.LocalCloudBoardAttestationBundle"
    )
    internal enum AttestationBundleWrapper {
        // the validated bundle does not expose all information we need so we need to keep both the raw and the
        // validated bundle
        case cloudAttestationBundle(unvalidated: AttestationBundle, validated: Validated.AttestationBundle?)
        case testOnlyAttestationBundle(TestOnlyAttestationBundle)
    }

    internal var attestationBundle: AttestationBundleWrapper

    /// Digest identifying the software release running on the associated node
    public var releaseDigest: String?

    /// Proxy-specific application data
    public struct ProxyAppData: Sendable {
        /// The set of digests of all compute software releases the proxy is willing to transitively trust in behalf
        /// of the client
        public var trustedReleaseSet: [String]
    }

    /// Compute-specific application data
    public struct ComputeAppData: Sendable {
        /// Compute metadata such as the boot ID
        public var metadata: [String: Data]
        public var ensembleId: String?
        public var bootId: String?
        public var rackId: String?
    }

    public enum AppData: Sendable {
        /// No available application data
        case none
        /// Proxy-specific application data
        case proxy(ProxyAppData)
        /// Compute-specific application data
        case compute(ComputeAppData)
    }

    /// Application-specific metadata included in the attestation
    public var appData: AppData

    /// /// Serializes the attestation bundle
    /// - Returns: The serialized bundle
    public func serializedData() throws -> Data {
        switch self.attestationBundle {
        case .cloudAttestationBundle(let unvalidatedBundle, _):
            return try unvalidatedBundle.serializedData()
        case .testOnlyAttestationBundle(let bundle):
            return try bundle.serializedData()
        }
    }

    /// Provides a JSON representation of the attestation bundle.
    /// - Returns: JSON representation. Throws if the JSON encoding fails.
    public func jsonString() throws -> String {
        switch self.attestationBundle {
        case .cloudAttestationBundle(let unvalidatedBundle, _):
            return try unvalidatedBundle.jsonString()
        case .testOnlyAttestationBundle(let bundle):
            return try bundle.jsonString()
        }
    }

    init(testOnlyAttestationBundle: TestOnlyAttestationBundle) {
        self.attestationBundle = AttestationBundleWrapper.testOnlyAttestationBundle(testOnlyAttestationBundle)
        self.releaseDigest = testOnlyAttestationBundle.releaseDigest

        switch testOnlyAttestationBundle.appData {
        case .none:
            self.appData = .none
        case .proxy(let proxyAppData):
            self.appData = .proxy(.init(trustedReleaseSet: proxyAppData.transitivelyTrustedReleaseDigests))
        case .compute(let computeAppData):
            self.appData = .compute(.init(
                metadata: computeAppData.metadata,
                ensembleId: nil,
                bootId: nil,
                rackId: nil
            ))
        }
    }

    /// Creates an instance from a raw attestation bundle and its validation result. The validation result is used
    /// to obtain the trusted release set can only be obtained from the validated attestation bundle.
    /// - Parameters:
    ///   - unvalidated: unvalidated raw attestation bundle.
    ///   - validatedBundle: The validated attestation bundle. If `nil`, the attestation is assumed to be a compute node
    ///   attestation without associated app data.
    ///   - publicKey: The public part of the attested key.
    init(
        unvalidated unvalidatedBundle: AttestationBundle,
        validated validatedBundle: Validated.AttestationBundle?
    ) throws {
        self.attestationBundle = AttestationBundleWrapper.cloudAttestationBundle(
            unvalidated: unvalidatedBundle,
            validated: validatedBundle
        )

        if let validatedBundle, let appData = validatedBundle.appData, appData.name == "Proxy Node" {
            self.releaseDigest = validatedBundle.releaseDigest?.hexString
            let metadata = try PrivateCloudCompute_ProxyNodeMetadata(unpackingAny: appData.metadata)
            self.appData = .proxy(.init(trustedReleaseSet: metadata.proxiedRelease.map { $0.digest.hexString }))
        } else {
            self.releaseDigest = try Release(bundle: unvalidatedBundle, evaluateTrust: false).sha256

            // Parse ensemble/boot/rack IDs from attestation app data
            var ensembleId: String?
            var bootId: String?
            var rackId: String?

            do {
                let protoBundle = try Proto_AttestationBundle(serializedBytes: unvalidatedBundle.serializedData())
                let protoAppData = try Proto_AppData(serializedBytes: protoBundle.appData)
                guard protoAppData.name == "Compute Node" else {
                    // Not a compute node, skip parsing
                    throw LocalCloudBoardClientError.internalError("Not a compute node attestation")
                }
                let appDataProto = try AttestationAppData(unpackingAny: protoAppData.metadata)
                ensembleId = String(data: appDataProto.ensembleID, encoding: .utf8)
                bootId = String(data: appDataProto.bootID, encoding: .utf8)
                rackId = String(data: appDataProto.rackID, encoding: .utf8)
            } catch {
                Self.logger
                    .error(
                        "Failed to parse ensemble/boot/rack IDs from attestation app data: \(error, privacy: .public)"
                    )
            }

            self.appData = .compute(.init(
                metadata: [:],
                ensembleId: ensembleId,
                bootId: bootId,
                rackId: rackId
            ))
        }
    }
}

extension Data {
    fileprivate var hexString: String {
        self.compactMap { String(format: "%02x", $0) }.joined()
    }
}
