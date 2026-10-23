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
import CloudBoardLogging
import Foundation
internal import HTTPClientStateMachine
import os

/// A means to make instances of ``AttestationValidatorProtocol`` for a specific request.
/// A request is tied to the attestation on a proxy, which then transitively indicates the trusted worker
/// release sets.
///
/// This implementation will detect the relevant validator based on the format of the attestation
/// It only functions with CloudAttestation based *proxy* attestations, but workers may be of different
/// types
final class AutoDetectingAttestationValidatorFactory: AttestationValidatorFactoryProtocol {
    private let enableTransitiveProofVerification: Bool
    private let transparencyCache: (any CloudAttestation.TransparencyCache & CloudAttestationV2.TransparencyCache)?
    private let pccEnvironment: CloudAttestation.Environment

    init(
        enableTransitiveProofVerification: Bool,
        transparencyCache: (any CloudAttestation.TransparencyCache & CloudAttestationV2.TransparencyCache)?,
        pccEnvironment: CloudAttestation.Environment
    ) {
        self.enableTransitiveProofVerification = enableTransitiveProofVerification
        self.transparencyCache = transparencyCache
        self.pccEnvironment = pccEnvironment
    }

    /// Make a validator that auto-detects the type of compute node attestations and validates it accordingly.
    ///
    /// Parameters:
    ///   - proxyAttestationBundle: the actual attestation of the proxy in use
    ///   - enableReleaseSetValidation: if true, the validator will enforce that the compute node attestation must run
    ///   a release that corresponds to the set of trusted releases associated with the provided proxyAttestationBundle
    func makeForProxyAttestation(
        rawProxyAttestationBundle: RawAttestationBundle,
        enableReleaseSetValidation: Bool
    ) async throws -> any AttestationValidatorProtocol {
        let cloudAttestationValidator = try CloudAttestationValidator(
            rawProxyAttestationBundle: rawProxyAttestationBundle,
            enableReleaseSetValidation: enableReleaseSetValidation,
            enableTransitiveProofVerification: self.enableTransitiveProofVerification,
            transparencyCache: self.transparencyCache
        )
        return try AutoDetectingAttestationValidator(
            cloudAttestationValidator: cloudAttestationValidator,
            cloudAttestationV2Validator: CloudAttestationV2Validator(
                rawProxyAttestationBundle: rawProxyAttestationBundle,
                transparencyCache: self.transparencyCache,
                pccEnvironment: self.pccEnvironment.v2PCCEnvironment
            ),
            testOnlyValidator: InMemoryAttestationValidator(
                proxiedReleaseDigests: cloudAttestationValidator.proxiedReleaseDigests,
                // the InMemory validator doesn't care about this - it's just for logging
                rawProxyAttestationBundle: rawProxyAttestationBundle,
                // unless there is a need for testing "pretend" releaseDigests there's no point having this
                // validation path active. Until that point it is simply supressed
                enableReleaseSetValidation: false
            )
        )
    }
}

final class AutoDetectingAttestationValidator: AttestationValidatorProtocol, Sendable {
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "AutoDetectingAttestationValidator"
    )

    // There is not point trying to generalise this to a mapping to any Validator
    // It only complicates things while the auto detection has to make use of heuristics and fallbacks
    // once we have clean mapping of the format of the attestation this can be done via geneneralised mapping

    let cloudAttestationValidator: CloudAttestationValidator
    let cloudAttestationV2Validator: CloudAttestationV2Validator
    let testOnlyValidator: InMemoryAttestationValidator

    init(
        cloudAttestationValidator: CloudAttestationValidator,
        cloudAttestationV2Validator: CloudAttestationV2Validator,
        testOnlyValidator: InMemoryAttestationValidator
    ) throws {
        self.cloudAttestationValidator = cloudAttestationValidator
        self.cloudAttestationV2Validator = cloudAttestationV2Validator
        self.testOnlyValidator = testOnlyValidator
    }

    var rawProxyAttestationBundle: RawAttestationBundle {
        self.cloudAttestationValidator.rawProxyAttestationBundle
    }

    /// This only applies to CloudAttestation based formats
    /// There is no point validating the TestOnly release digests as they don't contain valid ones
    /// right now
    var enableReleaseSetValidation: Bool {
        self.cloudAttestationValidator.enableReleaseSetValidation
    }

    var additionalDiagnosticDetails: String {
        return "proxyAttestationBundle: \(self.rawProxyAttestationBundle.base64EncodedString())"
    }

    /// This is for diagnostics only - they are simply ignored for the TestOnly format
    var proxiedReleaseDigests: [String] {
        self.cloudAttestationValidator.proxiedReleaseDigests
    }

    private enum AutoParse {
        case testOnly(TestOnlyAttestationBundle)
        case cloudAttestation(CloudAttestation.AttestationBundle)
        case cloudAttestationV2
    }

    private static func attemptTestOnlyParse(
        _ rawAttestationBundle: RawAttestationBundle
    ) -> Result<TestOnlyAttestationBundle, any Error>? {
        // This is a stronger check than the constructor as it does not assume that the format _should_
        // be the correct one.
        guard TestOnlyAttestationBundle.mightBeThisFormat(bundle: rawAttestationBundle) else {
            return nil
        }
        do {
            guard let parsed = try TestOnlyAttestationBundle(data: rawAttestationBundle) else {
                return nil
            }
            return .success(parsed)
        } catch {
            return .failure(error)
        }
    }

    /// Tries to work out the format, and parse it appropriately.
    ///
    /// Test-only bundles are checked first, then format detection for CloudAttestation v1 vs CloudAttestationV2
    /// is delegated to ``CloudAttestationFormatDetectingValidator/detectFormat``.
    private static func autoParse(_ rawAttestationBundle: RawAttestationBundle) throws -> AutoParse {
        // Try test-only attestation parsing first as it's cheap
        let testOnlyParse = Self.attemptTestOnlyParse(rawAttestationBundle)
        switch testOnlyParse {
        case .some(.success(let parsed)):
            return .testOnly(parsed)
        case .some(.failure(let testOnlyError)):
            // Looked like test-only format but failed to parse.
            // Try v1/V2 CloudAttestation format detection as fallback, but prefer the test-only error if that also
            // fails.
            do {
                let format = try CloudAttestationFormatDetectingValidator.detectFormat(rawAttestationBundle)
                switch format {
                case .cloudAttestation:
                    return try .cloudAttestation(CloudAttestation.AttestationBundle(data: rawAttestationBundle))
                case .cloudAttestationV2:
                    return .cloudAttestationV2
                }
            } catch {
                Self.logger.log(
                    "Error parsing bundle with hash \(rawAttestationBundle.keyID, privacy: .public) via format detection - as it appears to be TestFormat we consider that failure more informative, logging and ignoring this error: \(String(reportable: error))"
                )
                throw testOnlyError
            }
        case .none:
            // Not test-only — use the shared v1/V2 format detection
            let format = try CloudAttestationFormatDetectingValidator.detectFormat(rawAttestationBundle)
            switch format {
            case .cloudAttestation:
                return try .cloudAttestation(CloudAttestation.AttestationBundle(data: rawAttestationBundle))
            case .cloudAttestationV2:
                return .cloudAttestationV2
            }
        }
    }

    func validate(rawAttestationBundle: RawAttestationBundle) async throws -> ValidatedWorker {
        let parsed = try Self.autoParse(rawAttestationBundle)
        switch parsed {
        case .testOnly(let bundle):
            return try self.testOnlyValidator.validate(attestationBundle: bundle)
        case .cloudAttestation(let bundle):
            return try await self.cloudAttestationValidator.validate(attestationBundle: bundle)
        case .cloudAttestationV2:
            return try await self.cloudAttestationV2Validator.validate(rawAttestationBundle: rawAttestationBundle)
        }
    }

    func parseReleaseDigest(
        rawAttestationBundle: Data
    ) async throws -> String {
        let parsed = try Self.autoParse(rawAttestationBundle)
        switch parsed {
        case .testOnly(let bundle):
            return try self.testOnlyValidator.parseReleaseDigest(attestationBundle: bundle)
        case .cloudAttestation(let bundle):
            return try self.cloudAttestationValidator.parseReleaseDigest(attestationBundle: bundle)
        case .cloudAttestationV2:
            return try await self.cloudAttestationV2Validator
                .parseReleaseDigest(rawAttestationBundle: rawAttestationBundle)
        }
    }
}
