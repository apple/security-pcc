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
//  TPMClaims.swift
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

// MARK: - TPMClaims

/// Claims drawn purely from the TPM 2.0 quote command structure — the
/// `TPMS_ATTEST` the platform TPM signed plus the quoted PCR values — with no
/// dependence on any event log.
///
/// This is the host analogue of ``TDXClaims``: the hardware-rooted register
/// values the platform TPM attested. The boot and launch event logs are
/// projected separately into ``HostClaims``; policy reconciles the two by
/// matching each `pcrN` here against the corresponding `replayedPCRN` from
/// ``HostClaims``, exactly as `validate_ccel` matches
/// `tdx_claims.rtmrN == ccel_claims.replayedRTMRN`.
///
/// Trust model — IMPORTANT for policy authors: ``verified`` proves three things
/// together — (a) the quoted PCR map is internally consistent with the signed
/// `TPMS_ATTEST`, (b) the Titan endorsement key (EK) actually signed that
/// `TPMS_ATTEST` (an ECDSA-P256/SHA-256 signature over the marshaled quote
/// body), and (c) the Titan EK/DICE endorsement chain fully verifies back to the
/// pinned Google scribe roots (EK ← alias key ← DeviceID ← scribe roots). Since
/// the EK that signs the quote is the same key the chain roots, (b)+(c) together
/// bind this exact quote to this device. Because ``verified`` subsumes both the
/// signature and endorsement checks, ``titanFirmwareDigest`` and
/// ``titanDeviceIdentity`` are only sound once ``verified`` is `true`, exactly as
/// policy must establish TCB acceptance for the TDX evidence.
public struct TPMClaims: Claims.DefaultInitializableValue {
    /// `true` iff ALL of: (1) the signed `pcrSelect` selects exactly the PCR
    /// indices present in the quoted map and the bank hash over those values (in
    /// the TPM's canonical order) equals the `pcrDigest` inside the signed
    /// `TPMS_ATTEST` (binding the quoted PCR values AND their index labels to the
    /// quote body); (2) the Titan EK signed that `TPMS_ATTEST` (ECDSA-P256/
    /// SHA-256), so the quote body is cryptographically attributable to the
    /// endorsed key; and (3) the Titan EK/DICE endorsement chain verifies and
    /// roots to a pinned Google scribe root. Together these bind this exact
    /// quote — values, labels, and signer — to this device.
    public var verified: Bool? = nil

    /// TPM PCR bank the quote covers (e.g. `"sha256"`). `nil` when no SHA-256
    /// quote could be located/parsed.
    public var pcrBank: String? = nil

    /// The qualifying data the TPM signed (`TPMS_ATTEST.extraData`) — the
    /// freshness nonce. TPM-signature-bound once ``verified`` is `true` (it is
    /// covered by the same signature the EK made over the quote body), but its
    /// *freshness* is still policy's job: the `host` policy reconciles these
    /// bytes against `protobuf.hostChallenge` (the bundle's declared
    /// `HostAttestation.challenge`). Real Titan host quotes carry the raw
    /// challenge here verbatim — not the `SHA256(label ‖ …)` derivation the
    /// Confidential Space proto documents — so the policy comparison is a direct
    /// byte match. Until ``verified`` is `true`, treat it as attacker-controlled.
    public var extraData: Data? = nil

    /// Quoted value of PCR[0] — static CRTM / platform firmware.
    public var pcr0: Data? = nil
    /// Quoted value of PCR[17] — the DRTM (dynamic root of trust).
    public var pcr17: Data? = nil
    /// Quoted value of PCR[19] — the host launch register.
    public var pcr19: Data? = nil
    /// Quoted value of PCR[21] — the boot-services application register.
    public var pcr21: Data? = nil

    /// SHA-256 RW firmware hash of the Titan chip, read from the `rwHash` field
    /// of the EK certificate that endorses the quoting key. A fleet-stable Titan
    /// firmware measurement (the analogue of BMC/BIOS for the security chip).
    /// `nil` for non-Titan-endorsed hosts or an unparseable EK certificate.
    ///
    /// Trust note: this is only sound when ``verified`` is `true` — that flag
    /// requires the EK cert this value is read from to chain (EK ← alias key ←
    /// DeviceID ← pinned scribe roots) back to a Google root.
    public var titanFirmwareDigest: Data? = nil

    /// The Titan `DeviceIDCertificate` bytes — the stable, per-device DICE
    /// identity (Layer 0, derived from the chip's UDS and invariant across
    /// firmware updates) — from the endorsement's DICE cert chain. Its SHA-384
    /// digest is the device's `googleIdentityDigest` in the Device Identity
    /// Manifest. Distinct from ``titanFirmwareDigest``, which is the
    /// firmware-bound measurement carried in the alias-key/EK layer. `nil` for
    /// non-Titan hosts or an unparseable DICE chain.
    ///
    /// Trust note: sound only when ``verified`` is `true`.
    public var titanDeviceIdentity: Data? = nil

    public init() {}
}

// MARK: - PCR indices

/// PCR registers the bare-metal Titan host quotes. Stable on the wire; shared by
/// the TPM-quote and boot-event-log projections so both name the same register.
enum HostPCR {
    static let platformFirmware: UInt32 = 0
    static let drtm: UInt32 = 17
    static let launch: UInt32 = 19
    static let boot: UInt32 = 21
}

// MARK: - Generator

extension TPMClaims {
    /// Projects a host attestation's TPM quote into ``TPMClaims``.
    ///
    /// Resilient by design: if the quote can't be parsed the corresponding
    /// fields are left `nil` and the failure is logged, so policy sees missing
    /// claims (and the binding it requires absent) rather than a hard error. The
    /// platform TPM bank is SHA-256 on these hosts; a quote in any other bank is
    /// ignored (mirrors the SHA-384-only CCEL/CSEL generators).
    public struct Generator: ClaimsGenerator, Sendable {
        private static let logger = Logger(label: "com.apple.CloudAttestation.TPMClaims")

        public init() {}

        public func generateClaims(for tpmQuote: TpmQuote) async throws -> TPMClaims {
            var claims = TPMClaims()

            let sha256AlgID = UInt16(TPM.Alg.ID.sha256.rawValue)
            let sha256Quotes = tpmQuote.quotes.filter { $0.hashAlgorithm == UInt32(sha256AlgID) }
            guard let signedQuote = sha256Quotes.first else {
                Self.logger.error(
                    "No SHA-256 TPM quote found in host attestation; returning empty claims",
                    metadata: ["quoteCount": .stringConvertible(tpmQuote.quotes.count)]
                )
                return claims
            }
            if sha256Quotes.count > 1 {
                Self.logger.warning(
                    "Multiple SHA-256 host TPM quotes present; using the first and ignoring the rest",
                    metadata: ["sha256QuoteCount": .stringConvertible(sha256Quotes.count)]
                )
            }
            claims.pcrBank = "sha256"

            let quotedPCRs = signedQuote.pcrValues
            claims.pcr0 = quotedPCRs[HostPCR.platformFirmware]
            claims.pcr17 = quotedPCRs[HostPCR.drtm]
            claims.pcr19 = quotedPCRs[HostPCR.launch]
            claims.pcr21 = quotedPCRs[HostPCR.boot]

            // The checks below establish trust from the root down: (1) an
            // endorsed signer, (2) that signer's signature over the opaque quote
            // body, and only then (3) the quoted PCR map bound to that
            // now-trusted body. `verified` is their conjunction.

            // 1. The signer. Parse the Titan endorsement — the EK certificate
            // (whose `rwHash` is the firmware measurement) and the DICE cert
            // chain (whose DeviceID cert is the stable device identity) — and
            // verify it chains to a pinned Google scribe root. Present only on
            // Titan hosts; a non-Titan endorsement leaves both blobs empty. On
            // success `verify` returns the EK public key: the key that signs the
            // quote. A failure never throws, so `verified` folds in an untrusted
            // endorsement rather than the generator erroring out.
            let endorsement = tpmQuote.endorsement.titanEndorsement
            let ekCertBytes = endorsement.ekCert
            let diceCertChainBytes = endorsement.diceCertChain

            var ekCertificate: EKCertificate? = nil
            if !ekCertBytes.isEmpty {
                do {
                    let cert = try EKCertificate(consumingAll: Array(ekCertBytes))
                    ekCertificate = cert
                    claims.titanFirmwareDigest = Data(cert.header.rwHash.bytes)
                } catch {
                    Self.logger.error(
                        "Failed to parse Titan EK certificate; titanFirmwareDigest left nil",
                        metadata: ["error": .string(String(describing: error))]
                    )
                }
            }

            var diceChain: TitanDICEScribeCertificateChain? = nil
            if !diceCertChainBytes.isEmpty {
                do {
                    let chain = try TitanDICEScribeCertificateChain(consumingAll: Array(diceCertChainBytes))
                    diceChain = chain
                    claims.titanDeviceIdentity = Data(chain.deviceIDCertificate.encoded())
                } catch {
                    Self.logger.error(
                        "Failed to parse Titan DICE cert chain; titanDeviceIdentity left nil",
                        metadata: ["error": .string(String(describing: error))]
                    )
                }
            }

            var titanEndorsementVerified = false
            var endorsedEKPublicKey: ECP256PublicKey? = nil
            if let ekCertificate, let diceChain {
                do {
                    endorsedEKPublicKey = try TitanDICEVerifier().verify(ekCertificate: ekCertificate, with: diceChain)
                    titanEndorsementVerified = true
                } catch {
                    titanEndorsementVerified = false
                    Self.logger.error(
                        "Titan DICE endorsement chain failed to verify against pinned scribe roots; verified=false",
                        metadata: ["error": .string(String(describing: error))]
                    )
                }
            } else if !ekCertBytes.isEmpty || !diceCertChainBytes.isEmpty {
                // A partial/unparseable endorsement cannot be trusted.
                titanEndorsementVerified = false
                Self.logger.error("Incomplete Titan endorsement (missing or unparseable EK cert or DICE chain); verified=false")
            }

            // 2. The signature. The endorsed EK must have signed this exact
            // `TPMS_ATTEST` (ECDSA-P256/SHA-256 over the marshaled quote body).
            // Verifying it over the opaque bytes — before parsing — is what makes
            // the body trustworthy; it was previously deferred to policy.
            var signatureValid = false
            if let endorsedEKPublicKey {
                do {
                    signatureValid = try Self.verifyQuoteSignature(
                        tpmtSignature: signedQuote.tpmtSignature,
                        over: signedQuote.tpmsAttest,
                        with: endorsedEKPublicKey
                    )
                    if !signatureValid {
                        Self.logger.error("Host TPM quote signature did not verify under the endorsed Titan EK; verified=false")
                    }
                } catch {
                    Self.logger.error(
                        "Failed to verify host TPM quote signature; verified=false",
                        metadata: ["error": .string(String(describing: error))]
                    )
                }
            }

            // 3. The PCR-map binding. With the quote body's signature established,
            // parse the `TPMS_ATTEST`, surface the signed nonce, and require the
            // quoted PCR map to select exactly the signed `pcrSelect` indices
            // (label binding) and its bank hash over those values (in the TPM's
            // canonical order) to equal the signed `pcrDigest` (value binding).
            // `extraData` and the quoted PCR values are surfaced raw for
            // observability regardless; trust is gated by the conjunction below.
            // The magic must also be set to TPM.GeneratedValue.
            var pcrsValid = false
            var tpmGenerated = false
            do {
                let attest = try TPMDecoder().decode(TPMS_ATTEST.self, from: signedQuote.tpmsAttest)
                if attest.magic == TPM.GeneratedValue {
                    tpmGenerated = true
                } else {
                    tpmGenerated = false
                    Self.logger.error("Host TPMS_ATTEST has wrong magic value")
                }
                claims.extraData = Data(attest.extraData.buffer)
                if let pcrDigest = attest.quotePCRDigest,
                    let selectedPCRs = attest.quotePCRSelections?.first(where: { $0.bankAlgID == sha256AlgID })?.pcrs
                {
                    var hasher = SHA256()
                    var allPresent = true
                    for index in selectedPCRs {
                        guard let value = quotedPCRs[index] else {
                            allPresent = false
                            break
                        }
                        hasher.update(data: value)
                    }
                    let selectionMatches = Set(selectedPCRs) == Set(quotedPCRs.keys)
                    pcrsValid = allPresent && selectionMatches && Array(hasher.finalize()) == pcrDigest
                } else {
                    Self.logger.error("Host TPMS_ATTEST is not a quote / lacks a SHA-256 selection; verified=false")
                }
            } catch {
                Self.logger.error(
                    "Failed to decode host TPMS_ATTEST; extraData unset, verified=false",
                    metadata: ["error": .string(String(describing: error))]
                )
            }

            // Trust requires the endorsed signer, its signature over the quote
            // body, and the PCR-map binding to that body.
            claims.verified = titanEndorsementVerified && signatureValid && pcrsValid && tpmGenerated

            return claims
        }

        /// Verifies that `ekPublicKey` — the Titan EK proven to chain to a pinned
        /// scribe root — produced the signature carried in `tpmtSignature` over
        /// the marshaled `tpmsAttest`. Titan EKs are P-256 signing keys, so the
        /// scheme must be ECDSA over SHA-256; anything else is rejected.
        private static func verifyQuoteSignature(
            tpmtSignature: Data,
            over tpmsAttest: Data,
            with ekPublicKey: ECP256PublicKey
        ) throws -> Bool {
            let signature = try TPMDecoder().decode(TPMT_SIGNATURE.self, from: tpmtSignature)
            guard signature.hashAlgorithm == .sha256, let (r, s) = signature.ecdsaSignature else {
                Self.logger.error("Host TPM quote uses an unsupported signature scheme for a P-256 EK (expected ECDSA/SHA-256)")
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
