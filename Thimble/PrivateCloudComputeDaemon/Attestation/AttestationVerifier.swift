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

//
//  AttestationVerifier.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import CloudAttestation
import Foundation
import PrivateCloudCompute
import os.log

private let unreasonableDelay: Duration = .seconds(20)
private let maximumConcurrency: Int = 4

struct AttestationVerifier<
    FeatureFlagChecker: FeatureFlagCheckerProtocol,
    Validator: ValidatorProtocol
>: AttestationVerifierProtocol, Sendable {
    private let logger = tc2Logger(forCategory: .attestationVerifier)
    private let environment: TC2Environment
    private let featureFlagChecker: FeatureFlagChecker
    private let validator: Validator

    // The actual validation of the attestation has the potential to use
    // enough memory that we want to ensure we don't undertake too many
    // validations at once. We already do this in prefetch, but the limit
    // here is effectively global since we use one verifier instance for
    // the daemon.
    private let concurrencySemaphore: AsyncSemaphore

    init(
        environment: TC2Environment,
        featureFlagChecker: FeatureFlagChecker,
        validator: Validator
    ) {
        self.environment = environment
        self.featureFlagChecker = featureFlagChecker
        self.validator = validator
        self.concurrencySemaphore = AsyncSemaphore(value: maximumConcurrency)
    }

    func validate(
        attestation: Attestation,
        expectedNodeKind: NodeKind,
    ) async throws -> ValidatedAttestation {
        try await self.concurrencySemaphore.wait()
        defer { self.concurrencySemaphore.signal() }

        guard let unvalidatedBundle = attestation.attestationBundle else {
            throw TrustedRequestError(code: .missingAttestationBundle)
        }

        let bundle: AttestationBundle
        do {
            bundle = try AttestationBundle(data: unvalidatedBundle)
        } catch {
            // This is a protobuf decoding error; it means we have garbage bytes
            throw TrustedRequestError(code: .invalidAttestationBundle)
        }

        let publicKeyData: PublicKeyData
        let attestationExpiry: Date
        let validatedAttestation: Validated.AttestationBundle
        do {
            (publicKeyData, attestationExpiry, validatedAttestation) = try await withDelayAction(duration: unreasonableDelay) {
                logger.debug("validating attestation using mux validator")
                return try await validator.validate(bundle: bundle)
            } onDelay: {
                logger.error("latency issue: validate is taking longer than expected, delay=\(unreasonableDelay)")
            }
        } catch {
            logger.error("unable to verify attestation, environment=\(self.environment.name, privacy: .public) error=\(error)")
            throw error
        }

        try validateNodeKind(validatedAttestationBundle: validatedAttestation, expectedNodeKind: expectedNodeKind)

        if let routingHint = validatedAttestation.routingHint, let unvalidatedCellID = attestation.unvalidatedCellID {
            if routingHint != unvalidatedCellID {
                logger.error("RoutingHint mismatch detected for attestation=\(attestation.nodeID)")
                throw TrustedRequestError(code: .routingHintMismatch)
            }
        }

        logger.log("verified attestation bundle environment=\(self.environment.name, privacy: .public) publicKey=\(String(describing: publicKeyData)) keyExpiration=\(validatedAttestation.keyExpiration) attestationExpiry=\(attestationExpiry)")

        let publicKey = gatewayConfig(publicKeyData: publicKeyData)

        return .init(
            attestation: attestation,
            nodeKind: expectedNodeKind,
            publicKey: publicKey,
            attestationExpiry: attestationExpiry,
            udid: validatedAttestation.udid,
            validatedCellID: validatedAttestation.routingHint
        )
    }

    func udid(attestation: Attestation) async throws -> String? {
        guard let unvalidatedBundle = attestation.attestationBundle else {
            throw TrustedRequestError(code: .missingAttestationBundle)
        }

        let bundle = try AttestationBundle(data: unvalidatedBundle)
        return bundle.withUnvalidatedAttestationBundle { bundle in
            bundle.udid
        }
    }

    private func gatewayConfig(publicKeyData: PublicKeyData) -> Data {
        // TODO: We should avoid doing this here but rather do it on the network layer.
        let raw = publicKeyData.raw
        var result = Data(capacity: raw.count + 9)
        result.append(0)  // key ID
        result.append(contentsOf: [0x00, 0x20])  // KEM ID
        result.append(contentsOf: raw)
        result.append(contentsOf: [0x00, 0x04])  // Length of the following in bytes
        result.append(contentsOf: [0x00, 0x01])  // KDF ID
        result.append(contentsOf: [0x00, 0x01])  // AEAD ID
        return result
    }

    private func validateNodeKind(
        validatedAttestationBundle: Validated.AttestationBundle,
        expectedNodeKind: NodeKind
    ) throws {
        let validatedNodeKind = try self.validatedNodeKind(validatedAttestationBundle: validatedAttestationBundle)
        if expectedNodeKind != validatedNodeKind {
            logger.error("node kind mismatch expectedNodeKind=\(expectedNodeKind, privacy: .public), validatedNodeKind=\(validatedNodeKind, privacy: .public)")
            throw TrustedRequestError(code: .attestationKindMismatch)
        }
    }

    private func validatedNodeKind(validatedAttestationBundle: Validated.AttestationBundle) throws -> NodeKind {
        guard let attestationType = CloudAttestation.PCC.AttestationType(from: validatedAttestationBundle) else {
            logger.error("attestation kind can't be determined from attestationType=nil")
            throw TrustedRequestError(code: .unexpectedAttestationKind)
        }

        switch attestationType {
        case .computeNode:
            return .direct
        case .proxyNode:
            return .proxy
        @unknown default:
            logger.error("attestation kind can't be determined from attestationType=\(String(describing: attestationType))")
            throw TrustedRequestError(code: .unexpectedAttestationKind)
        }
    }
}

protocol ValidatorProtocol: Sendable {
    func validate(bundle: AttestationBundle) async throws -> (key: PublicKeyData, expiration: Date, attestation: Validated.AttestationBundle)
}

extension CloudAttestation.MuxValidator: ValidatorProtocol {}

func cloudAttestationValidator(for environment: TC2Environment) -> CloudAttestation.MuxValidator {
    let cloudAttestationEnvironment = CloudAttestation.Environment(environment)
    return CloudAttestation.PCC.AutoValidator(environment: cloudAttestationEnvironment)
}
