# Copyright © 2026 Apple Inc. All Rights Reserved.

# APPLE INC.
# PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
# PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
# IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
# 1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
# 2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
# 3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# 4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
# You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
# EA1937
# 10/02/2024

package gcpv1.platformcertificate

claims := input.claims

default environment := "production"

environment := input.environment

# Pinned platform certificate roots, keyed by SubjectDN → base64 SHA384(DER).
#
# ---- Division of labour with the Swift verifier ----
#
# `claims.platformCertificate.verified` is the Swift layer's answer to a purely
# cryptographic question: does the chain verify (signatures, validity dates, path
# constraints, and on Apple platforms the DC-attestation policy plus CRL
# revocation) to a root Apple actually operates? Rego cannot answer that — it
# sees claims, not bytes.
#
# This table answers the complementary question the Swift layer deliberately does
# NOT: which of those roots is acceptable *here*. `AppleTrustAnchors` is
# environment-independent on purpose, so policy is the only place that scopes
# roots and is always the tightening layer — anything pinned below was already
# accepted cryptographically, and every rejection is attributable to a violation
# message here. See AppleTrustAnchors.swift for the other half.
#
# Soundness rests on `trustChainSubjects`/`trustChainFingerprints` being derived
# from the *verified* chain the verifier returns, not from the attacker-supplied
# `appleChain` input (see GCPv1PlatformCertificateClaims.Generator). If that ever
# changes, this whole module becomes theatre while still passing its tests.
#
# Subjects are the RFC 4514-shaped strings produced by
# DistinguishedName.canonicalString (most-specific RDN first).

# Apple's production Data Center Attestation root. The ONLY root accepted in
# `qa` and `production` — a node in either environment must carry a certificate
# issued by the real DCA hierarchy.
production_roots := {"C=US,ST=California,O=Apple Inc.,CN=Data Center Attestation Online Root CA - G3": "HC9ftZcf2Z0a6/YYGTrNFF0LJNcMX94pg21QPPDeN2feUmf7q+SoJRyjFh+3etG/"}

# Additional roots accepted ONLY in `development`. Note these two are trusted by
# different mechanisms, and the difference matters:
#
#   - Apple's DCA *test* root IS in `AppleTrustAnchors.recognized`, so a
#     test-rooted chain verifies cryptographically in every environment. This
#     table is the only thing keeping it out of qa and production.
#
#   - The self-signed `CloudAttestationV2 Dev CA` is NOT a recognized anchor at
#     all — its private key is a checked-in test fixture, so anyone can mint a
#     chain rooted there. It reaches this table only when a caller injects its own
#     verifier (tests, and Apple-internal tooling that mints development chains at
#     runtime). Pinning it here is what lets those paths pass the development
#     policy; it is never trusted by the library itself.
development_only_roots := {
	"C=US,ST=California,O=Apple Inc.,CN=Test Data Center Attestation Online Root CA - G3": "mQfMsJLNEHpUBlYYwaP8g6/olKvrKqllQySJtUfRth8u2XAVYcUy0itsJjYWFkhD",
	"CN=CloudAttestationV2 Dev CA": "27u0po3jS5tTu9nIQVrxVN/q1EcPuQRgGfxy/BlcxpGJ1QW88lqwDdOj9ZYcFqdS",
}

roots_by_environment := {
	"development": object.union(production_roots, development_only_roots),
	"qa": production_roots,
	"production": production_roots,
}

# An unrecognized environment gets the strictest set rather than no set at all,
# so a typo'd environment can never widen the trust boundary.
trusted_roots := object.get(roots_by_environment, environment, production_roots)

default valid_root := false

# The chain must verify, be exactly leaf+root (one parent), and that parent must
# be one of the roots pinned for this environment — matched on both SubjectDN and
# SHA384 fingerprint.
#
# Deliberately does NOT require `manifest_valid`, which is gated separately.
#
# METADATA
# entrypoint: true
valid_root if {
	claims.platformCertificate.verified == true
	count(claims.platformCertificate.trustChainSubjects) == 1
	count(claims.platformCertificate.trustChainFingerprints) == 1
	subject := claims.platformCertificate.trustChainSubjects[0]
	expected_fp := trusted_roots[subject]
	claims.platformCertificate.trustChainFingerprints[0] == expected_fp
}

# Bind the platform cert's provisioning-time device identity manifest to the manifest the
# live attestation evidence (TDX PCK + GPU leaves + Titan DeviceID) currently produces.
# Without this check a stale or mis-issued platform cert from a different node would still
# pass policy. The cert manifest claim is only populated when the chain itself verifies, so
# this rule implicitly requires a verified platform cert.
#
# METADATA
# entrypoint: true
default manifest_valid := false

manifest_valid if {
	claims.platformCertificate.deviceIdentityManifest != null
	claims.computedDeviceIdentityManifest != null
	claims.platformCertificate.deviceIdentityManifest == claims.computedDeviceIdentityManifest
}

# ---- Platform certificate diagnostics ----
#
# METADATA
# entrypoint: true
violation contains "platformCertificate claim is missing" if {
	not claims.platformCertificate
}

violation contains "platformCertificate.verified is false" if {
	claims.platformCertificate
	not claims.platformCertificate.verified
}

violation contains msg if {
	claims.platformCertificate.verified
	n := count(claims.platformCertificate.trustChainSubjects)
	n != 1
	msg := sprintf("platformCertificate trust chain expected leaf+root (1 parent), got %d", [n])
}

violation contains msg if {
	claims.platformCertificate.verified
	count(claims.platformCertificate.trustChainSubjects) == 1
	subject := claims.platformCertificate.trustChainSubjects[0]
	not trusted_roots[subject]
	msg := sprintf("platformCertificate root subject %q is not in the trust set pinned for environment %q", [subject, environment])
}

violation contains msg if {
	claims.platformCertificate.verified
	count(claims.platformCertificate.trustChainSubjects) == 1
	count(claims.platformCertificate.trustChainFingerprints) == 1
	subject := claims.platformCertificate.trustChainSubjects[0]
	expected_fp := trusted_roots[subject]
	actual_fp := claims.platformCertificate.trustChainFingerprints[0]
	actual_fp != expected_fp
	msg := sprintf("platformCertificate root fingerprint mismatch for %q: expected %q, got %q", [subject, expected_fp, actual_fp])
}

violation contains "platformCertificate.deviceIdentityManifest is missing" if {
	claims.platformCertificate.verified
	claims.platformCertificate.deviceIdentityManifest == null
}

violation contains "computedDeviceIdentityManifest is missing" if {
	claims.platformCertificate.verified
	claims.computedDeviceIdentityManifest == null
}

violation contains msg if {
	claims.platformCertificate.deviceIdentityManifest != null
	claims.computedDeviceIdentityManifest != null
	claims.platformCertificate.deviceIdentityManifest != claims.computedDeviceIdentityManifest
	msg := sprintf(
		"platformCertificate.deviceIdentityManifest %v does not match computedDeviceIdentityManifest %v",
		[claims.platformCertificate.deviceIdentityManifest, claims.computedDeviceIdentityManifest],
	)
}
