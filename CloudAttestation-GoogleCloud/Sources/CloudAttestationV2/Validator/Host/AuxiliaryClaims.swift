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
//  AuxiliaryClaims.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Crypto
import Foundation
import GCPv1
import Logging
import SwiftTPM
import Titan

// MARK: - AuxiliaryClaims

/// Claims drawn from the host attestation's **auxiliary NV attestations**
/// (`TpmAuxiliaryAttestation.signed_nvs`) — values the platform TPM reports
/// *outside* the PCRs, each certified by its own `TPM2_NV_Certify`.
///
/// On Titan hosts the TPM is electrically integrated with the CPU such that it
/// can report, via a reserved NV index, the number of warm resets the CPU has
/// undergone since the last power cycle. That counter lives at NV index
/// `0x01C10005` and is the reason this claim exists: nothing in the measured
/// boot chain records a soft reboot, so the PCRs alone cannot distinguish a
/// freshly booted host from one that has been warm-reset out from under a
/// running workload. Its value is a hard 2 by contract with Google — Bowcaster's
/// boot flow performs exactly two warm resets before the workload launches, and
/// any other count is out of spec (enforced by `gcpv1.host` in `host.rego`).
///
/// This is a sibling of ``TPMClaims``, not a part of it: the NV attestations are
/// a separate protobuf field, signed separately, and verify independently of the
/// quote. They do share a root of trust — the same Titan endorsement key signs
/// both — so ``AuxiliaryClaims/NVClaims/verified`` subsumes the same endorsement
/// chain check that ``TPMClaims/verified`` performs.
public struct AuxiliaryClaims: Codable, Claims.DefaultInitializableValue {
    /// One entry per signed NV index, in protobuf order — a 1:1 projection of
    /// `TpmAuxiliaryAttestation.signed_nvs`. Empty when the host attestation
    /// carries no auxiliary attestations.
    ///
    /// Each element verifies independently, so policy must check
    /// ``NVClaims/verified`` on the specific entry it reads rather than assuming
    /// a single fleet-wide verdict.
    public var nvs: [NVClaims] = []

    public init() {}
}

// MARK: - NVClaims

extension AuxiliaryClaims {
    /// A single auxiliary NV-index attestation — the projection of one
    /// `TpmAuxiliaryAttestation.SignedNvCertify`, produced by `TPM2_NV_Certify`.
    ///
    /// Trust model — IMPORTANT for policy authors: ``verified`` is the only gate.
    /// Both ``index`` and ``value`` are read from structures an attacker controls
    /// until the signature is checked, so treat them as untrusted whenever
    /// ``verified`` is not `true`:
    ///
    /// - ``value`` comes from the signed `TPMS_ATTEST` body, never from the
    ///   sibling `nv_data` protobuf field (which is unauthenticated and, in real
    ///   Bowcaster captures, empty).
    /// - ``index`` comes from the *unsigned* `TPMS_NV_PUBLIC`, but ``verified``
    ///   requires its recomputed Name (`nameAlg ‖ H(TPMS_NV_PUBLIC)`) to equal
    ///   the `indexName` inside the signed body — so a verified entry's index
    ///   label is bound to the signature too. Without that check an attacker
    ///   could relabel one index's signed value as another's.
    public struct NVClaims: Codable, Claims.ValueProtocol {
        /// `true` iff ALL of: (1) the Titan endorsement chain verifies to a
        /// pinned Google scribe root (the same chain ``TPMClaims/verified``
        /// requires); (2) the endorsed EK signed this `TPMS_ATTEST`
        /// (ECDSA-P256/SHA-256); (3) the attestation is TPM generated
        /// (`magic == TPM_GENERATED_VALUE`) and is an NV certification carrying
        /// inline contents (`TPM_ST_ATTEST_NV`); and (4) the Name recomputed
        /// from the accompanying `TPMS_NV_PUBLIC` equals the `indexName` the TPM
        /// signed, binding ``index`` to ``value``.
        public var verified: Bool? = nil

        /// The NV index handle the attestation covers (e.g. `0x01C10005`, the
        /// Titan warm-reset counter), from the accompanying `TPMS_NV_PUBLIC`.
        /// Bound to the signature only once ``verified`` is `true`. `nil` when
        /// the public area could not be parsed.
        public var index: UInt32? = nil

        /// The certified contents of the NV index, exactly as they appear in the
        /// signed `TPMS_NV_CERTIFY_INFO` — raw bytes, uninterpreted. For the
        /// Titan warm-reset counter this is an 8-byte big-endian counter. `nil`
        /// when the attestation could not be decoded or is a
        /// `TPM_ST_ATTEST_NV_DIGEST` (which carries only a digest of the
        /// contents, not the contents themselves).
        public var value: Data? = nil

        /// The qualifying data the TPM signed (`TPMS_ATTEST.extraData`) — the
        /// freshness nonce, the same challenge the quote carries. Surfaced so
        /// policy can bind this NV attestation to the bundle's declared host
        /// challenge (`protobuf.hostChallenge`) exactly as it does for
        /// ``TPMClaims/extraData``; without that, a verified-but-stale NV
        /// attestation could be replayed alongside a fresh quote.
        public var extraData: Data? = nil

        public init() {}
    }
}

// MARK: - Generator

extension AuxiliaryClaims {
    /// Projects a host attestation's auxiliary NV attestations into
    /// ``AuxiliaryClaims``.
    ///
    /// Resilient by design: a malformed entry is surfaced with `verified ==
    /// false` and whatever fields could be read, so policy sees an explicitly
    /// rejected entry rather than an absent one it might misread as "no NV index
    /// was attested".
    ///
    /// Takes the whole `HostAttestation` because verification needs the Titan
    /// endorsement, which lives on the sibling `tpm_quote` field — the NV
    /// attestations carry no endorsement of their own.
    public struct Generator: ClaimsGenerator, Sendable {
        private static let logger = Logger(label: "com.apple.CloudAttestation.AuxiliaryClaims")

        public init() {}

        public func generateClaims(for hostAttestation: HostAttestation) async throws -> AuxiliaryClaims {
            var claims = AuxiliaryClaims()

            let signedNVs = hostAttestation.auxAttestation.signedNvs
            guard !signedNVs.isEmpty else {
                return claims
            }

            // The endorsement is the root of trust for these attestations: the
            // same Titan EK that signs the quote signs each NV body. Resolve it
            // once, then verify every entry against it. A failure never throws —
            // it folds into each entry's `verified`.
            let endorsedEKPublicKey = Self.endorsedEKPublicKey(for: hostAttestation.tpmQuote)

            claims.nvs = signedNVs.enumerated().map { index, signedNV in
                Self.nvClaims(for: signedNV, at: index, endorsedEKPublicKey: endorsedEKPublicKey)
            }

            return claims
        }

        /// Verifies the Titan EK/DICE endorsement chain carried on the quote and
        /// returns the endorsed EK public key — the key that signs both the
        /// quote and the NV attestations. `nil` when the endorsement is absent,
        /// unparseable, or fails to root to a pinned Google scribe root, which
        /// leaves every NV entry unverified.
        private static func endorsedEKPublicKey(for tpmQuote: TpmQuote) -> ECP256PublicKey? {
            let endorsement = tpmQuote.endorsement.titanEndorsement
            guard !endorsement.ekCert.isEmpty, !endorsement.diceCertChain.isEmpty else {
                if !endorsement.ekCert.isEmpty || !endorsement.diceCertChain.isEmpty {
                    logger.error("Incomplete Titan endorsement (missing EK cert or DICE chain); NV attestations cannot be verified")
                }
                return nil
            }

            do {
                let ekCertificate = try EKCertificate(consumingAll: Array(endorsement.ekCert))
                let diceChain = try TitanDICEScribeCertificateChain(consumingAll: Array(endorsement.diceCertChain))
                return try TitanDICEVerifier().verify(ekCertificate: ekCertificate, with: diceChain)
            } catch {
                logger.error(
                    "Titan endorsement failed to verify against pinned scribe roots; NV attestations cannot be verified",
                    metadata: ["error": .string(String(describing: error))]
                )
                return nil
            }
        }

        /// Projects a single `TPM2_NV_Certify` attestation, verifying it against
        /// the endorsed EK. `index` identifies the entry in log messages only.
        private static func nvClaims(
            for signedNV: TpmAuxiliaryAttestation.SignedNvCertify,
            at index: Int,
            endorsedEKPublicKey: ECP256PublicKey?
        ) -> AuxiliaryClaims.NVClaims {
            var claim = AuxiliaryClaims.NVClaims()

            // The NV index label comes from the unsigned public area. The
            // marshaled bytes are retained because the index Name digests the
            // encoding, not the parsed fields.
            var nvPublic: TPMS_NV_PUBLIC? = nil
            if let parsed = try? TPMDecoder().decode(TPMS_NV_PUBLIC.self, from: signedNV.tpmsNvPublic) {
                nvPublic = parsed
                claim.index = parsed.nvIndex
            } else {
                logger.error(
                    "Failed to decode TPMS_NV_PUBLIC for auxiliary NV attestation; index left nil, verified=false",
                    metadata: ["nvAttestationIndex": .stringConvertible(index)]
                )
            }

            // The endorsed EK must have signed this exact TPMS_ATTEST. Checked
            // over the opaque bytes before parsing, so the body is only
            // interpreted once it is attributable to the endorsed key.
            var signatureValid = false
            if let endorsedEKPublicKey {
                do {
                    signatureValid = try Self.verifyAttestSignature(
                        tpmtSignature: signedNV.tpmtSignature,
                        over: signedNV.tpmsAttest,
                        with: endorsedEKPublicKey
                    )
                    if !signatureValid {
                        logger.error(
                            "Auxiliary NV attestation signature did not verify under the endorsed Titan EK; verified=false",
                            metadata: ["nvAttestationIndex": .stringConvertible(index)]
                        )
                    }
                } catch {
                    logger.error(
                        "Failed to verify auxiliary NV attestation signature; verified=false",
                        metadata: [
                            "nvAttestationIndex": .stringConvertible(index),
                            "error": .string(String(describing: error)),
                        ]
                    )
                }
            }

            // With the signature established, parse the body: surface the signed
            // contents and nonce, and bind the index label by recomputing the NV
            // Name from the public area and matching the signed `indexName`.
            var tpmGenerated = false
            var nameBound = false
            do {
                let attest = try TPMDecoder().decode(TPMS_ATTEST.self, from: signedNV.tpmsAttest)
                tpmGenerated = attest.magic == TPM.GeneratedValue
                if !tpmGenerated {
                    logger.error(
                        "Auxiliary NV TPMS_ATTEST has wrong magic value; verified=false",
                        metadata: ["nvAttestationIndex": .stringConvertible(index)]
                    )
                }
                claim.extraData = Data(attest.extraData.buffer)

                // `nvContents` is nil for a TPM_ST_ATTEST_NV_DIGEST, which
                // certifies only a digest of the contents — there is no value to
                // surface, so such an entry can never be `verified`.
                if let contents = attest.nvContents {
                    claim.value = Data(contents)
                } else {
                    logger.error(
                        "Auxiliary NV attestation carries no inline NV contents (not a TPM_ST_ATTEST_NV); value left nil, verified=false",
                        metadata: ["nvAttestationIndex": .stringConvertible(index)]
                    )
                }

                if let signedName = attest.nvIndexName, let computedName = nvPublic?.name(marshaled: signedNV.tpmsNvPublic) {
                    nameBound = signedName == computedName
                    if !nameBound {
                        logger.error(
                            "Auxiliary NV index Name does not match the signed indexName; verified=false",
                            metadata: ["nvAttestationIndex": .stringConvertible(index)]
                        )
                    }
                }
            } catch {
                logger.error(
                    "Failed to decode auxiliary NV TPMS_ATTEST; value unset, verified=false",
                    metadata: [
                        "nvAttestationIndex": .stringConvertible(index),
                        "error": .string(String(describing: error)),
                    ]
                )
            }

            claim.verified = signatureValid && tpmGenerated && nameBound && claim.value != nil
            return claim
        }

        /// Verifies that `ekPublicKey` — the Titan EK proven to chain to a pinned
        /// scribe root — produced the signature carried in `tpmtSignature` over
        /// the marshaled `tpmsAttest`. Titan EKs are P-256 signing keys, so the
        /// scheme must be ECDSA over SHA-256; anything else is rejected.
        private static func verifyAttestSignature(
            tpmtSignature: Data,
            over tpmsAttest: Data,
            with ekPublicKey: ECP256PublicKey
        ) throws -> Bool {
            let signature = try TPMDecoder().decode(TPMT_SIGNATURE.self, from: tpmtSignature)
            guard signature.hashAlgorithm == .sha256, let (r, s) = signature.ecdsaSignature else {
                logger.error("Auxiliary NV attestation uses an unsupported signature scheme for a P-256 EK (expected ECDSA/SHA-256)")
                return false
            }
            // TPM2B ECC parameters are big-endian and may omit leading zero bytes;
            // swift-crypto's raw representation needs each scalar left-padded to
            // the 32-byte P-256 order size.
            let rawSignature = Self.leftPadded(r, to: 32) + Self.leftPadded(s, to: 32)
            let ecdsaSignature = try P256.Signing.ECDSASignature(rawRepresentation: rawSignature)
            // `isValidSignature(_:for:)` hashes `tpmsAttest` with SHA-256, matching
            // the TPM's ECDSA/SHA-256 signature over the marshaled TPMS_ATTEST.
            return try ekPublicKey.p256PublicKey.isValidSignature(ecdsaSignature, for: tpmsAttest)
        }

        /// Left-pads `bytes` with leading zeroes to `width`, returning it
        /// unchanged when already at least `width` long.
        private static func leftPadded(_ bytes: [UInt8], to width: Int) -> [UInt8] {
            guard bytes.count < width else { return bytes }
            return [UInt8](repeating: 0, count: width - bytes.count) + bytes
        }
    }
}
