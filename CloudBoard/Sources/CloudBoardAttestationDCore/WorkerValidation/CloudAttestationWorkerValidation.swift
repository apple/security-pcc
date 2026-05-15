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

import CloudAttestation
import CloudBoardAttestationDAPI
import CloudBoardCommon
import CloudBoardLogging
import CloudBoardMetrics
import CryptoKit
import Foundation
import InternalSwiftProtobuf
import os

/// A means to make instances of ``AttestationValidatorProtocol`` for a specific request.
/// A request is tied to the attestation on a proxy, which then transitively indicates the trusted worker
/// release sets.
final class CloudAttestationValidatorFactory: AttestationValidatorFactoryProtocol {
    /// Make a validator which will validate compute node attestations using CloudAttestation
    /// Parameters:
    ///   - proxyAttestationBundle: the actual attestation of the proxy in use
    ///   - enableReleaseSetValidation: if true, the validator will enforce that the compute node attestation must run
    ///   a release that corresponds to the set of trusted releases associated with the provided proxyAttestationBundle
    func makeForProxyAttestation(
        rawProxyAttestationBundle: Data,
        enableReleaseSetValidation: Bool
    ) async throws -> any AttestationValidatorProtocol {
        return try CloudAttestationValidator(
            rawProxyAttestationBundle: rawProxyAttestationBundle,
            enableReleaseSetValidation: enableReleaseSetValidation
        )
    }
}

final class CloudAttestationValidator: AttestationValidatorProtocol, Sendable {
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CloudAttestationValidator"
    )

    let validator: any Validator
    let rawProxyAttestationBundle: Data
    let enableReleaseSetValidation: Bool

    var additionalDiagnosticDetails: String {
        return "proxyAttestationBundle: \(self.rawProxyAttestationBundle.base64EncodedString())"
    }

    /// Note: this is for diagnostics, actual validation happens inside CloudAttestation framework
    let proxiedReleaseDigests: [String]

    init(
        rawProxyAttestationBundle: Data,
        enableReleaseSetValidation: Bool
    ) throws {
        self.enableReleaseSetValidation = enableReleaseSetValidation
        self.rawProxyAttestationBundle = rawProxyAttestationBundle
        // we end up parsing twice, that's a shame, but it's off the hot path
        self.proxiedReleaseDigests = try CloudAttestationProvider.parseProxiedReleaseDigests(
            attestationBundle: rawProxyAttestationBundle
        )
        if enableReleaseSetValidation {
            let proxyAttestationBundle: AttestationBundle
            do {
                proxyAttestationBundle = try AttestationBundle(data: rawProxyAttestationBundle)
            } catch {
                throw CloudAttestationValidatorError.unrecognisedAttestationFormat(
                    description: error.localizedDescription
                )
            }
            self.validator = PCC.ComputeNodeValidator(proxyingAttestation: proxyAttestationBundle)
        } else {
            self.validator = NodeValidator()
        }
    }

    func validate(rawAttestationBundle: Data) async throws -> ValidatedWorker {
        let attestationBundle = try AttestationBundle(data: rawAttestationBundle)
        let (key, expiration, validatedAttestation) = try await validator.validate(bundle: attestationBundle)
        let udid = validatedAttestation.udid
        guard case .curve25519(let rawKey) = key else {
            throw CloudAttestationValidatorError.unexpectedPublicKeyType
        }
        var appDataMap: [String: Data] = [:]
        do {
            if let metadata = validatedAttestation.appData?.metadata {
                if validatedAttestation.appData?.name == "Compute Node" {
                    let attestationAppData = try AttestationAppData(unpackingAny: metadata)
                    appDataMap[ComputeNodeAppDataKeys.rackID] = attestationAppData.rackID
                    appDataMap[ComputeNodeAppDataKeys.bootID] = attestationAppData.bootID
                    appDataMap[ComputeNodeAppDataKeys.ensembleID] = attestationAppData.ensembleID
                }
            }
        } catch {
            Self.logger.error("Failed to parse Attestation AppData for compute node: \(error)")
        }

        var releaseDigest = validatedAttestation.releaseDigest?.hexString
        if releaseDigest == nil {
            Self.logger.error("validated attestation does not contain releaseDigest, attempting to parse ourselves")
            // This may only apply to older workers, but for now just parse it ourselves
            releaseDigest = try Release(bundle: attestationBundle, evaluateTrust: false).sha256
        }
        guard let releaseDigest else {
            throw CloudAttestationValidatorError.releaseDigestUnavailable
        }

        return try .init(
            expiration: expiration,
            publicKey: .init(rawRepresentation: rawKey),
            releaseDigest: releaseDigest,
            appData: appDataMap,
            udid: udid
        )
    }

    func parseReleaseDigest(
        rawAttestationBundle: Data
    ) throws -> String {
        let parsed = try AttestationBundle(data: rawAttestationBundle)
        let release = try Release(bundle: parsed)
        return release.sha256
    }
}

enum CloudAttestationValidatorError: ReportableError, Equatable {
    case unexpectedPublicKeyType
    case unrecognisedAttestationFormat(description: String)
    case releaseDigestUnavailable

    var publicDescription: String {
        switch self {
        case .unexpectedPublicKeyType: "unexpectedPublicKeyType"
        case .unrecognisedAttestationFormat(let description):
            "unrecognisedAttestationFormat(\(description))"
        case .releaseDigestUnavailable: "releaseDigestUnavailable"
        }
    }
}
