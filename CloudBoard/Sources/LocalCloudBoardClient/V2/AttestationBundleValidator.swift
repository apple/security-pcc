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

internal import CloudAttestation
@_spi(HPKEAlgID) import CryptoKit
import Foundation
internal import HTTPClientStateMachine
import os

extension PCCHarness {
    /// Validates and parses attestation bundles for PCC nodes
    struct AttestationBundleValidator: Sendable {
        static let logger: os.Logger = .init(
            subsystem: "com.apple.cloudos.cloudboard",
            category: "LocalCloudBoardClient.AttestationBundleValidator"
        )

        let attestationEnvironment: CloudAttestation.Environment
        private let relAttestationContinuation: AsyncStream<AttestationBundle>.Continuation
        let relAttestationStream: AsyncStream<AttestationBundle>

        init(attestationEnvironment: CloudAttestation.Environment) {
            self.attestationEnvironment = attestationEnvironment
            let (stream, continuation) = AsyncStream<AttestationBundle>.makeStream()
            self.relAttestationStream = stream
            self.relAttestationContinuation = continuation
        }

        /// Parse and validate an attestation bundle, returning the public key and validated bundle
        func parseAndValidate(_ attestationBundle: Data) async throws
        -> (Curve25519.KeyAgreement.PublicKey, LocalCloudBoardAttestationBundle) {
            if let fakeBundle = try TestOnlyAttestationBundle(data: attestationBundle) {
                Self.logger.log(
                    """
                    Received \(attestationBundle.count, privacy: .public)-byte attestation bundle \
                    that parsed as a test-only bundle format: \(fakeBundle.version, privacy: .public)
                    """
                )
                return (fakeBundle.publicKey, LocalCloudBoardAttestationBundle(testOnlyAttestationBundle: fakeBundle))
            } else {
                Self.logger.log("Received CloudAttestation attestation bundle. Extracting public key.")
                do {
                    let bundle = try AttestationBundle(data: attestationBundle)
                    let validator = CloudAttestation.NodeValidator(environment: self.attestationEnvironment)
                    let (key, validity, validatedAttestation) = try await validator.validate(bundle: bundle)
                    Self.logger.log(
                        "Verified attestation bundle with validity \(validity, privacy: .public) and expiration \(validatedAttestation.keyExpiration, privacy: .public), key: \(String(describing: key), privacy: .public)"
                    )

                    let rawKey: Data
                    switch key {
                    case .x963(let rawData):
                        rawKey = rawData
                    case .curve25519(let rawData):
                        rawKey = rawData
                    default:
                        Self.logger.log("Unknown key type in attestation bundle")
                        throw LocalCloudBoardGRPCClientError.unknownKeyType(String(describing: key))
                    }
                    let publicKey = try Curve25519.KeyAgreement.PublicKey(rawKey, kem: .Curve25519_HKDF_SHA256)
                    return try (
                        publicKey,
                        LocalCloudBoardAttestationBundle(unvalidated: bundle, validated: validatedAttestation)
                    )
                } catch {
                    Self.logger.log(
                        "Failed to extract key from CloudAttestation attestation bundle: error (\(error, privacy: .public))"
                    )
                    throw LocalCloudBoardGRPCClientError.failedToParseCloudAttestationBundle(error)
                }
            }
        }

        /// Parse a compute node attestation bundle without validation
        func parseComputeNodeAttestationBundle(_ attestationBundle: Data) throws
        -> LocalCloudBoardAttestationBundle {
            do {
                if let fakeBundle = try TestOnlyAttestationBundle(data: attestationBundle) {
                    return LocalCloudBoardAttestationBundle(testOnlyAttestationBundle: fakeBundle)
                } else {
                    let bundle = try AttestationBundle(data: attestationBundle)
                    return try LocalCloudBoardAttestationBundle(unvalidated: bundle, validated: nil)
                }
            } catch {
                Self.logger.log(
                    "Failed to extract key from CloudAttestation attestation bundle: error (\(error, privacy: .public))"
                )
                throw LocalCloudBoardGRPCClientError.failedToParseCloudAttestationBundle(error)
            }
        }

        /// Run structured validation loop for compute node attestations from request execution log entries.
        /// These attestations can be validated retroactively (after the response is sent).
        func runRequestExecutionLogAttestationValidator(
            attestationStream: AsyncStream<AttestationBundle>
        ) async {
            for await bundle in attestationStream {
                await self.validateComputeNodeAttestationInRequestExecutionLogEntry(bundle: bundle)
            }
        }

        /// Validate compute node attestation from request execution log entry.
        /// This validation happens asynchronously in the background.
        private func validateComputeNodeAttestationInRequestExecutionLogEntry(
            bundle: AttestationBundle
        ) async {
            do {
                let validator = CloudAttestation.NodeValidator(environment: self.attestationEnvironment)
                let (key, validity, validatedAttestation) = try await validator.validate(bundle: bundle)
                Self.logger.log("""
                Verified attestation bundle for compute node in request execution log entry
                    validity: \(validity, privacy: .public),
                    expiration: \(validatedAttestation.keyExpiration, privacy: .public),
                    key: \(String(describing: key), privacy: .public)
                """)
            } catch {
                Self.logger.error(
                    "Attestation validation failed for compute node attestation in request execution log entry: \(error)"
                )
            }
        }

        /// Queue a request execution log attestation bundle for validation
        func queueRELAttestationForValidation(bundle: AttestationBundle) {
            self.relAttestationContinuation.yield(bundle)
        }
    }
}
