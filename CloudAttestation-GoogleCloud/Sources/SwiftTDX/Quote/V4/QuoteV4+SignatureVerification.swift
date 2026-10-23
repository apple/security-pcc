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
//  Quote+SignatureVerification.swift
//  CloudAttestationV2
//
//  Created by David Zech on 1/15/26.
//

import Foundation
import Crypto
import X509
import SwiftASN1

extension V4.Quote {

    package struct VerifyOptions: Sendable {
        package var trustAnchors: CertificateStore = .intelSGXRoots
    }

    package func verify(options: VerifyOptions? = nil) async throws {
        let options = options ?? VerifyOptions()
        try await self.verifyHeaderAndBody(options: options)
    }

    private func verifyHeaderAndBody(options: VerifyOptions) async throws {
        // V4 really only supports P-256

        // Verify the Quoting Enclave so we can trust the Attestation Key
        try await self.verifyQuotingEnclave(options: options)

        // Now we can trust the AttestationKey, verify Header || Body
        var digest = SHA256()
        digest.update(data: header.raw)
        digest.update(data: body.raw)

        let attestationKey = try P256.Signing.PublicKey(rawRepresentation: self.signatureData.ecdsaAttestationKey.bytes)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: self.signatureData.signature.bytes)

        guard attestationKey.isValidSignature(signature, for: digest.finalize()) else {
            throw V4.VerificationError.invalidTDSignature
        }
    }

    private func verifyQuotingEnclave(options: VerifyOptions) async throws {
        guard case .qeReportCertificationData(let certData) = self.signatureData.qeCertificationData.data else {
            throw V4.VerificationError.missingQEReportCertificationData
        }

        guard case .concatenatedPCKCertChain(let certChain) = certData.qeCertificationData.data else {
            throw V4.VerificationError.missingPCKCertChain
        }

        // 1. Validate PCK CertChain to get PCK Public Key.
        // 2. Validate Enclave Report Body Signature using PCK Public Key
        // 2. Validate Attestation Key by checking Enclave Report Body's Report Data

        let certs = try parseConcatenatedCerts(data: certChain)
        let pckCert = try await evaluatePCKCertificateChain(certificates: certs, options: options)

        let pckPublicKey = pckCert.publicKey

        guard let publicKey = P256.Signing.PublicKey(pckPublicKey) else {
            throw V4.VerificationError.invalidPCKPublicKey
        }

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: certData.qeReportSignature.bytes)
        let digest = SHA256.hash(data: certData.qeReport.raw)

        guard publicKey.isValidSignature(signature, for: digest) else {
            throw V4.VerificationError.invalidQESignature
        }

        // now check that reportData in the quoting enclave matches SHA256(attestationKey || QE Auth Data) || [32 of UInt8(0)]
        let reportData = [UInt8](SHA256.hash(data: signatureData.ecdsaAttestationKey.bytes + certData.qeAuthenticationData.bytes)) + [UInt8](repeating: 0, count: 32)

        guard reportData == certData.qeReport.reportData.bytes else {
            throw V4.VerificationError.invalidQEReportData
        }
    }

    private func evaluatePCKCertificateChain(certificates: [X509.Certificate], options: VerifyOptions) async throws -> PCKCertificate {
        var verifier = X509.Verifier(rootCertificates: options.trustAnchors) {
            RFC5280Policy()
        }

        guard let leaf = certificates.first else {
            throw V4.VerificationError.missingPCKCertChain
        }

        let result = await verifier.validate(leaf: leaf, intermediates: .init(certificates[1...])) { diagnostic in
            // TODO: log something here
        }

        switch result {
        case .validCertificate(let validatedCertificateChain):
            return PCKCertificate(validatedCertificateChain.leaf)
        case .couldNotValidate(_):
            throw V4.VerificationError.invalidPCKCertChain
        }
    }

    private func parseConcatenatedCerts(data: [UInt8]) throws -> [X509.Certificate] {
        guard let str = String(bytes: data, encoding: .utf8) else {
            throw V4.VerificationError.invalidPCKCertChain
        }
        let pems = try PEMDocument.parseMultiple(pemString: str)

        return try pems.map { pem in
            try X509.Certificate(pemDocument: pem)
        }
    }
}

extension V4 {
    enum VerificationError: Error {
        case missingQEReportCertificationData
        case missingPCKCertChain
        case invalidPCKCertChain
        case invalidPCKPublicKey
        case invalidTrustAnchors
        case trustEvaluationError(error: Error)
        case invalidQESignature
        case invalidQEReportData
        case invalidTDSignature
        case internalError(error: Error)
    }
}
