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

import AppleCertificates
import CloudBoardLogging
import CloudBoardMetrics
import Dispatch
import Foundation
import GRPCClientConfiguration
import InternalGRPC
import Network
import os
import Security
import Security_Private.SecCertificatePriv

extension GRPCTLSConfiguration {
    private static let verifyQueue =
        DispatchQueue(label: "com.apple.cloudos.cloudboardd.GRPCTLSConfiguration.policyVerifyQueue")

    fileprivate static let policyValidatorLogger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "TLSPolicyValidator"
    )

    // All PCC compute nodes present ACDC identity certificates. This wildcard matches any
    // valid compute node regardless of zone or UDID. Hardcoded because the pattern is
    // environment-independent (unlike ROPES' per-env MG/IG-pinned APRNs) and only certs
    // chaining to SDR/Narrative root CAs can satisfy the trust evaluation.
    // swiftlint:disable:next force_try
    package static let persistentServicePeerPolicyAPRN =
        try! PolicyAPRN(string: "aprn:apple:acdc::*:system-v0:type/compute/udid/*")

    /// Builds a `ServerVerification` suitable for client-side PolicyAPRN validation of the server's certificate.
    package static func policyAPRNServerVerification(
        expectedPolicyAPRNs: [PolicyAPRN],
        metricsSystem: MetricsSystem
    ) -> GRPCTLSConfiguration.ServerVerification {
        .init(
            verifyBlock: self.policyValidationBlock(
                expectedPolicyAPRNs: expectedPolicyAPRNs,
                metricsSystem: metricsSystem
            ),
            queue: self.verifyQueue
        )
    }

    package static func policyValidationBlock(
        expectedPolicyAPRNs: [PolicyAPRN],
        metricsSystem: MetricsSystem
    ) -> sec_protocol_verify_t {
        return { _, trustRef, complete in
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()

            Self.policyValidatorLogger.info(
                "PolicyAPRN validation starting, expecting peer to match one of: \(expectedPolicyAPRNs.map(\.description), privacy: .public)"
            )

            var rc = SecTrustSetAnchorCertificates(
                trust,
                SDRIdentityTranslator.sdrRootCAs + NarrativeValidator.appleCorporateRootCASecCerts as CFArray
            )
            if rc != errSecSuccess {
                Self.policyValidatorLogger
                    .error("Unable to trust SDR/Narrative root CA certs, error \(rc, privacy: .public)")
                complete(false)
                Self.emitTLSVerificationFailure(metricsSystem: metricsSystem, failure: .untrustedRootCA)
                return
            }

            // Disable hostname verification — identity is validated via APRN matching.
            rc = SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
            if rc != errSecSuccess {
                Self.policyValidatorLogger.error("Unable to override trust policy, error \(rc, privacy: .public)")
                complete(false)
                Self.emitTLSVerificationFailure(metricsSystem: metricsSystem, failure: .unexpectedCertEvaluationFailure)
                return
            }

            var trustError: CFError?
            let trustResult = SecTrustEvaluateWithError(trust, &trustError)
            guard trustResult else {
                if let trustError {
                    Self.policyValidatorLogger.error(
                        "Unable to validate cert, error: \(String(unredacted: trustError as Error), privacy: .public)"
                    )
                } else {
                    Self.policyValidatorLogger.error("Unable to validate cert with no error")
                }
                complete(false)
                Self.emitTLSVerificationFailure(metricsSystem: metricsSystem, failure: .invalidCertChain)
                return
            }

            guard let untypedChain = SecTrustCopyCertificateChain(trust) else {
                Self.policyValidatorLogger.error("Missing cert chain, validation failed.")
                complete(false)
                Self.emitTLSVerificationFailure(metricsSystem: metricsSystem, failure: .unexpectedNoCertChain)
                return
            }

            guard let chain = untypedChain as? [SecCertificate] else {
                Self.policyValidatorLogger.error(
                    "Unable to unwrap the chain to [SecCertificate], have \(untypedChain, privacy: .public), validation failed."
                )
                complete(false)
                Self.emitTLSVerificationFailure(metricsSystem: metricsSystem, failure: .notAnX509Cert)
                return
            }

            guard let leaf = chain.first else {
                Self.policyValidatorLogger.error("Cert chain is empty after successful trust evaluation")
                complete(false)
                Self.emitTLSVerificationFailure(metricsSystem: metricsSystem, failure: .unexpectedNoCertChain)
                return
            }
            Self.policyValidatorLogger.info(
                "Cert chain has \(chain.count, privacy: .public) certificates, leaf subject: \(SecCertificateCopySubjectSummary(leaf) as String? ?? "<unknown>", privacy: .public)"
            )

            let certAPRNs: [APRN]
            if leaf.hasExtension(oid: NarrativeValidator.narrativeExtensionOID) {
                Self.policyValidatorLogger.debug("Leaf certificate is a Narrative certificate")
                do {
                    certAPRNs = try NarrativeValidator.validateChain(trustedCertChain: chain)
                } catch {
                    Self.policyValidatorLogger.error(
                        "Error extracting APRNs for chain \(chain, privacy: .public), \(String(unredacted: error), privacy: .public), validation failed"
                    )
                    complete(false)
                    Self.emitTLSVerificationFailure(metricsSystem: metricsSystem, failure: .aprnExtractionFailure)
                    return
                }
            } else {
                Self.policyValidatorLogger.debug("Leaf certificate is an SDR certificate")
                do {
                    certAPRNs = try [SDRIdentityTranslator.validateChainAndComputeAPRN(trustedCertChain: chain)]
                } catch {
                    Self.policyValidatorLogger.error(
                        "Error computing APRN for chain \(chain, privacy: .public), \(String(unredacted: error), privacy: .public), validation failed"
                    )
                    complete(false)
                    Self.emitTLSVerificationFailure(metricsSystem: metricsSystem, failure: .aprnComputationFailure)
                    return
                }
            }

            Self.policyValidatorLogger.info(
                "Extracted \(certAPRNs.count, privacy: .public) APRN(s) from peer certificate"
            )
            for (i, certAPRN) in certAPRNs.enumerated() {
                Self.policyValidatorLogger.info(
                    "  certAPRN[\(i, privacy: .public)]: \(certAPRN, privacy: .public)"
                )
            }

            // Convert local APRNs to AppleCertificates.APRN and match against PolicyAPRNs
            var anyConversionSucceeded = false
            for certAPRN in certAPRNs {
                guard let acAPRN = try? AppleCertificates.APRN(string: certAPRN.description) else {
                    Self.policyValidatorLogger.warning(
                        "Unable to convert local APRN \(certAPRN, privacy: .public) to AppleCertificates.APRN, skipping"
                    )
                    continue
                }
                anyConversionSucceeded = true
                let batchResult = APRNMatcher.matchBatch(aprn: acAPRN, policies: expectedPolicyAPRNs)
                if !batchResult.matched.isEmpty {
                    Self.policyValidatorLogger.info(
                        "APRN \(certAPRN, privacy: .public) MATCHED policies: \(batchResult.matched.map(\.description), privacy: .public)"
                    )
                    complete(true)
                    return
                } else {
                    Self.policyValidatorLogger.error(
                        "APRN \(certAPRN, privacy: .public) did NOT match any policy. Checked against: \(batchResult.notMatched.map(\.description), privacy: .public)"
                    )
                }
            }

            if !anyConversionSucceeded {
                Self.policyValidatorLogger.error(
                    "All \(certAPRNs.count, privacy: .public) APRN(s) failed conversion to AppleCertificates.APRN"
                )
                Self.emitTLSVerificationFailure(metricsSystem: metricsSystem, failure: .aprnExtractionFailure)
                complete(false)
                return
            }

            Self.policyValidatorLogger.error(
                "PolicyAPRN validation FAILED. Cert APRNs: \(certAPRNs.map(\.description), privacy: .public), expected PolicyAPRNs: \(expectedPolicyAPRNs.map(\.description), privacy: .public)"
            )
            Self.emitTLSVerificationFailure(metricsSystem: metricsSystem, failure: .untrustedAPRN)
            complete(false)
        }
    }

    private static func emitTLSVerificationFailure(metricsSystem: MetricsSystem, failure: TLSVerificationFailure) {
        metricsSystem.emit(
            Metrics.TLSConfiguration.TLSVerificationErrorCounter(action: .increment, failureReason: failure.rawValue)
        )
    }
}

extension SecCertificate {
    package func hasExtension(oid: String) -> Bool {
        return SecCertificateCopyExtensionValue(
            self,
            oid as CFString,
            nil
        ) != nil
    }
}

package enum TLSVerificationFailure: String {
    case aprnComputationFailure = "APRN Computation Failure"
    case aprnExtractionFailure = "APRN Extraction Failure"
    case evaluationCallbackNotInvoked = "Evaluation Callback Not Invoked"
    case invalidCertChain = "Invalid Cert Chain"
    case notAnX509Cert = "Not an X509 Cert"
    case unexpectedCertEvaluationFailure = "Unexpected Cert Evaluation Failure"
    case unexpectedNoCertChain = "Unexpected No Cert Chain"
    case unexpectedCertChainLength = "Unexpected Cert Chain Length"
    case untrustedRootCA = "Untrusted Root CA"
    case untrustedAPRN = "Untrusted APRN"
    case unexpectedIntermediateOIDExtensionValue = "Unexpected Intermediate OID Extension Value"
}
