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

package gcpv1.platformcertificate_test

import data.gcpv1.platformcertificate

production_root_subject := "C=US,ST=California,O=Apple Inc.,CN=Data Center Attestation Online Root CA - G3"

production_root_fp := "HC9ftZcf2Z0a6/YYGTrNFF0LJNcMX94pg21QPPDeN2feUmf7q+SoJRyjFh+3etG/"

dca_test_root_subject := "C=US,ST=California,O=Apple Inc.,CN=Test Data Center Attestation Online Root CA - G3"

dca_test_root_fp := "mQfMsJLNEHpUBlYYwaP8g6/olKvrKqllQySJtUfRth8u2XAVYcUy0itsJjYWFkhD"

dev_root_subject := "CN=CloudAttestationV2 Dev CA"

dev_root_fp := "27u0po3jS5tTu9nIQVrxVN/q1EcPuQRgGfxy/BlcxpGJ1QW88lqwDdOj9ZYcFqdS"

manifest := {
	"intelIdentityDigest": "intel-digest",
	"nvidiaIdentityDigest": ["nvidia-digest-0", "nvidia-digest-1"],
	"googleIdentityDigest": "google-digest",
}

# Claims for a verified leaf+root chain rooted in `subject`/`fp`, with the cert's
# manifest agreeing with the manifest computed from the live evidence.
claims_rooted_in(subject, fp) := {"claims": {
	"platformCertificate": {
		"verified": true,
		"trustChainSubjects": [subject],
		"trustChainFingerprints": [fp],
		"deviceIdentityManifest": manifest,
	},
	"computedDeviceIdentityManifest": manifest,
}}

input_for(environment, subject, fp) := object.union(
	claims_rooted_in(subject, fp),
	{"environment": environment},
)

# ---- Environment-scoped root pinning ----
#
# The production DCA root is the only root accepted in qa and production; the DCA
# test root and the self-signed dev CA are accepted only in development.

test_production_root_valid_in_production if {
	platformcertificate.valid_root with input as input_for("production", production_root_subject, production_root_fp)
}

test_production_root_valid_in_qa if {
	platformcertificate.valid_root with input as input_for("qa", production_root_subject, production_root_fp)
}

test_production_root_valid_in_development if {
	platformcertificate.valid_root with input as input_for("development", production_root_subject, production_root_fp)
}

test_test_root_rejected_in_production if {
	not platformcertificate.valid_root with input as input_for("production", dca_test_root_subject, dca_test_root_fp)
}

test_test_root_rejected_in_qa if {
	not platformcertificate.valid_root with input as input_for("qa", dca_test_root_subject, dca_test_root_fp)
}

test_test_root_valid_in_development if {
	platformcertificate.valid_root with input as input_for("development", dca_test_root_subject, dca_test_root_fp)
}

test_dev_root_rejected_in_production if {
	not platformcertificate.valid_root with input as input_for("production", dev_root_subject, dev_root_fp)
}

test_dev_root_rejected_in_qa if {
	not platformcertificate.valid_root with input as input_for("qa", dev_root_subject, dev_root_fp)
}

test_dev_root_valid_in_development if {
	platformcertificate.valid_root with input as input_for("development", dev_root_subject, dev_root_fp)
}

# An absent `environment` must not widen the trust boundary: it falls back to the
# production-only set.
test_absent_environment_defaults_to_production_only if {
	platformcertificate.valid_root with input as claims_rooted_in(production_root_subject, production_root_fp)
	not platformcertificate.valid_root with input as claims_rooted_in(dev_root_subject, dev_root_fp)
}

# ...and neither may an unrecognized one.
test_unknown_environment_defaults_to_production_only if {
	platformcertificate.valid_root with input as input_for("not-an-environment", production_root_subject, production_root_fp)
	not platformcertificate.valid_root with input as input_for("not-an-environment", dev_root_subject, dev_root_fp)
}

test_violation_names_the_environment if {
	violations := platformcertificate.violation with input as input_for("qa", dev_root_subject, dev_root_fp)
	sprintf("platformCertificate root subject %q is not in the trust set pinned for environment \"qa\"", [dev_root_subject]) in violations
}

# ---- Chain shape / verification ----

test_invalid_when_claim_missing if {
	not platformcertificate.valid_root with input as {"claims": {}}
}

test_invalid_when_unverified if {
	unverified := {"claims": {"platformCertificate": {
		"verified": false,
		"trustChainSubjects": [production_root_subject],
		"trustChainFingerprints": [production_root_fp],
		"deviceIdentityManifest": manifest,
	}}}

	not platformcertificate.valid_root with input as unverified
}

test_invalid_when_root_not_pinned if {
	not platformcertificate.valid_root with input as claims_rooted_in("CN=Some Other CA", production_root_fp)
}

test_invalid_when_fingerprint_mismatches if {
	not platformcertificate.valid_root with input as claims_rooted_in(production_root_subject, "AAAA")
}

# A chain deeper than leaf+root is rejected: the pinned map only speaks to
# direct roots, so an unexpected intermediate must not slip through.
test_invalid_when_chain_too_deep if {
	deep := {"claims": {
		"platformCertificate": {
			"verified": true,
			"trustChainSubjects": ["CN=Intermediate", production_root_subject],
			"trustChainFingerprints": ["AAAA", production_root_fp],
			"deviceIdentityManifest": manifest,
		},
		"computedDeviceIdentityManifest": manifest,
	}}

	not platformcertificate.valid_root with input as deep
}

test_no_violations_when_valid if {
	count(platformcertificate.violation) == 0 with input as input_for("production", production_root_subject, production_root_fp)
}

test_violation_claim_missing if {
	violations := platformcertificate.violation with input as {"claims": {}}
	"platformCertificate claim is missing" in violations
}

test_violation_unverified if {
	violations := platformcertificate.violation with input as {"claims": {"platformCertificate": {"verified": false}}}
	"platformCertificate.verified is false" in violations
}

test_violation_chain_too_deep if {
	violations := platformcertificate.violation with input as {"claims": {"platformCertificate": {
		"verified": true,
		"trustChainSubjects": ["CN=Intermediate", production_root_subject],
		"trustChainFingerprints": ["AAAA", production_root_fp],
	}}}
	"platformCertificate trust chain expected leaf+root (1 parent), got 2" in violations
}

test_violation_fingerprint_mismatch if {
	violations := platformcertificate.violation with input as claims_rooted_in(production_root_subject, "AAAA")
	some v in violations
	startswith(v, "platformCertificate root fingerprint mismatch")
}

# ---- Device identity manifest binding ----

test_manifest_valid if {
	platformcertificate.manifest_valid with input as claims_rooted_in(production_root_subject, production_root_fp)
}

# A pinned, verified chain is not enough: the cert's provisioning-time manifest
# must equal the manifest the live evidence produces, or a cert issued for a
# different node would pass.
test_manifest_mismatch_rejected if {
	claims := {"claims": {
		"platformCertificate": {
			"verified": true,
			"trustChainSubjects": [production_root_subject],
			"trustChainFingerprints": [production_root_fp],
			"deviceIdentityManifest": manifest,
		},
		"computedDeviceIdentityManifest": {"intelIdentityDigest": "a-different-intel-digest"},
	}}

	not platformcertificate.manifest_valid with input as claims

	# Root pinning is unaffected — the two are gated separately, and only the
	# manifest rule fails here.
	platformcertificate.valid_root with input as claims

	violations := platformcertificate.violation with input as claims
	some v in violations
	startswith(v, "platformCertificate.deviceIdentityManifest ")
}

# A cert minted before the Titan/Google identity was provisioned must not match a
# bundle whose evidence now carries one (and vice versa).
test_manifest_mismatch_on_google_identity_alone if {
	claims := {"claims": {
		"platformCertificate": {
			"verified": true,
			"trustChainSubjects": [production_root_subject],
			"trustChainFingerprints": [production_root_fp],
			"deviceIdentityManifest": object.remove(manifest, ["googleIdentityDigest"]),
		},
		"computedDeviceIdentityManifest": manifest,
	}}

	not platformcertificate.manifest_valid with input as claims
}

test_manifest_invalid_when_cert_manifest_missing if {
	claims := {"claims": {
		"platformCertificate": {
			"verified": true,
			"trustChainSubjects": [production_root_subject],
			"trustChainFingerprints": [production_root_fp],
			"deviceIdentityManifest": null,
		},
		"computedDeviceIdentityManifest": manifest,
	}}

	not platformcertificate.manifest_valid with input as claims
	"platformCertificate.deviceIdentityManifest is missing" in platformcertificate.violation with input as claims
}

test_manifest_invalid_when_computed_manifest_missing if {
	claims := {"claims": {
		"platformCertificate": {
			"verified": true,
			"trustChainSubjects": [production_root_subject],
			"trustChainFingerprints": [production_root_fp],
			"deviceIdentityManifest": manifest,
		},
		"computedDeviceIdentityManifest": null,
	}}

	not platformcertificate.manifest_valid with input as claims
	"computedDeviceIdentityManifest is missing" in platformcertificate.violation with input as claims
}
