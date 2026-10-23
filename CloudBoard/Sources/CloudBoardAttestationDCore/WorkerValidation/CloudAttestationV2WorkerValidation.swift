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

import CloudAttestation
import CloudAttestationV2
import CloudBoardAttestationDAPI
import CloudBoardCommon
import CloudBoardLogging
import Common
import CryptoKit
import Foundation
import InternalSwiftProtobuf
import os
import PrivateCloudCompute
import SwiftProtobuf

final class CloudAttestationV2Validator: AttestationValidatorProtocol, Sendable {
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CloudAttestationV2Validator"
    )

    let rawProxyAttestationBundle: RawAttestationBundle
    let enableReleaseSetValidation: Bool = false
    // V2 doesn't use proxied release digests — policy engine handles trust evaluation
    let proxiedReleaseDigests: [String] = []
    let clock: (@Sendable () -> Date)?

    private let validator: UniversalValidator
    private let pccEnvironment: PrivateCloudCompute.Environment

    init(
        rawProxyAttestationBundle: RawAttestationBundle,
        transparencyCache: (any CloudAttestationV2.TransparencyCache)?,
        pccEnvironment: PrivateCloudCompute.Environment,
        clock: (@Sendable () -> Date)? = nil
    ) throws {
        self.rawProxyAttestationBundle = rawProxyAttestationBundle

        let proxyAttestationBundle = try CloudAttestation.AttestationBundle(data: rawProxyAttestationBundle)
        let proxyCertificateTransparencyProofs = try PrivateCloudCompute.TransparencyLogProofs(
            proxyAttestationBundle.proto.certificateTransparencyProofs.proofs
        )
        let proxyTransparencyProofs = try PrivateCloudCompute.TransparencyLogProofs(
            proxyAttestationBundle.proto.transparencyProofs.proofs
        )
        let transitiveVerifier = PCCTransparencyLog.TransitiveVerifier(
            certificateProofs: proxyCertificateTransparencyProofs,
            softwareProofs: proxyTransparencyProofs,
            firmwareProofs: proxyTransparencyProofs,
            transparencyProver: PCCTransparencyLog(environment: pccEnvironment),
            transparencyCache: transparencyCache
        )
        self.validator = UniversalValidator(transparencyVerifier: transitiveVerifier)
        self.pccEnvironment = pccEnvironment
        self.clock = clock
    }

    func validate(rawAttestationBundle: RawAttestationBundle) async throws -> ValidatedWorker {
        let bundle = try CloudAttestationV2.AttestationBundle(data: rawAttestationBundle)
        let validatedBundle = try await self.validator.validate(
            bundle: bundle,
            against: UniversalValidator.policy(for: self.pccEnvironment),
            options: ValidatorOptions(clock: self.clock),
        )
        let rawKey = validatedBundle.publicKey.data
        Self.logger.log("CloudAttestationV2 validation succeeded")

        let release = try validatedBundle.workloadRelease()
        let releaseDigest = try Data(release.digest()).hexString

        let deviceManifestDER = try validatedBundle.deviceIdentityManifest().derRepresentation
        let hardwareID = HardwareID.cloudAttestationV2(
            identifier: Data(SHA256.hash(data: deviceManifestDER)).hexString
        )

        var appDataMap: [String: Data] = [:]
        do {
            if let rawAppData = try bundle.appData {
                let cloudAttestationV2AppData = try CloudAttestationV2.PrivateCloudCompute_AppData(
                    serializedBytes: rawAppData
                )
                if cloudAttestationV2AppData.name == "Compute Node", cloudAttestationV2AppData.hasMetadata {
                    let attestationAppData = try AttestationAppData(
                        serializedBytes: cloudAttestationV2AppData.metadata.value
                    )
                    appDataMap[ComputeNodeAppDataKeys.rackID] = attestationAppData.rackID
                    appDataMap[ComputeNodeAppDataKeys.bootID] = attestationAppData.bootID
                    appDataMap[ComputeNodeAppDataKeys.ensembleID] = attestationAppData.ensembleID

                    let rackIDString = String(data: attestationAppData.rackID, encoding: .utf8) ?? "<not decodable>"
                    let bootIDString = String(data: attestationAppData.bootID, encoding: .utf8) ?? "<not decodable>"
                    let ensembleIDString = String(data: attestationAppData.ensembleID, encoding: .utf8) ??
                        "<not decodable>"
                    Self.logger.info(
                        """
                        Extracted attestation app data
                        rackID=\(rackIDString, privacy: .public)
                        bootID=\(bootIDString, privacy: .public)
                        ensembleID=\(ensembleIDString, privacy: .public)
                        """
                    )
                } else {
                    Self.logger.error("App data does not contain Compute Node metadata")
                }
            }
        } catch {
            Self.logger.error("Failed to parse CloudAttestationV2 appData: \(error)")
        }

        return try .init(
            expiration: validatedBundle.expiration,
            publicKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawKey),
            releaseDigest: releaseDigest,
            appData: appDataMap,
            hardwareID: hardwareID,
            appIdentifiers: nil
        )
    }

    func parseReleaseDigest(rawAttestationBundle: RawAttestationBundle) async throws -> String {
        do {
            let start = ContinuousClock.now
            let bundle = try CloudAttestationV2.AttestationBundle(data: rawAttestationBundle)
            let validatedBundle = try await bundle.validateStructure()
            let release = try validatedBundle.workloadRelease()
            return try Data(release.digest()).hexString
        } catch {
            Self.logger.log("Failed to parse release digest: \(String(reportable: error), privacy: .public)")
            return "<failed-to-parse>"
        }
    }
}

enum CloudAttestationV2ValidatorError: ReportableError, Equatable {
    case unexpectedPublicKeyType
    case unsupportedBundleFormat
    case unmappableEnvironment(rawValue: String)

    var publicDescription: String {
        switch self {
        case .unexpectedPublicKeyType: "cloudAttestationV2.unexpectedPublicKeyType"
        case .unsupportedBundleFormat: "cloudAttestationV2.unsupportedBundleFormat"
        case .unmappableEnvironment(let rawValue): "cloudAttestationV2.unmappableEnvironment(\(rawValue))"
        }
    }
}

// Conversion of CloudAttestation v1 to CloudAttestation v2 proto types

extension PrivateCloudCompute.TransparencyLogProofs {
    init(_ proofs: CloudAttestation.PrivateCloudCompute_TransparencyLog_ATLogProofs) throws {
        self = try .init(serializedBytes: proofs.serializedData())
    }
}

extension CloudAttestation.Environment {
    /// Maps CloudAttestation v1 environment to CloudAttestation v2 environment
    var v2PCCEnvironment: PrivateCloudCompute.Environment {
        get throws {
            switch self {
            case .dev: .dev
            case .ephemeral: .ephemeral
            case .perf: .perf
            case .quarantine: .quarantine
            case .qa: .qa
            case .staging: .staging
            case .uat: .carry
            case .carry: .carry
            case .liveon: .liveon
            case .production: .production
            case .qa2Primary: .qa2Primary
            case .qa2Internal: .qa2Internal
            @unknown default:
                throw CloudAttestationV2ValidatorError.unmappableEnvironment(rawValue: self.rawValue)
            }
        }
    }
}
