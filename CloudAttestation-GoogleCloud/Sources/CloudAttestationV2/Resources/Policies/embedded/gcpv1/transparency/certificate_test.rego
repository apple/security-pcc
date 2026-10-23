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

package gcpv1.transparency_test

import data.gcpv1.transparency

# Certificate transparency is enforced only for Bowcaster, identified by the
# `googleIdentityDigest` (Titan DeviceID) its platform certificate carries — so every
# enforcement case below needs a Bowcaster-shaped platform certificate claim. Only that
# digest matters to the gate; the rest of the manifest is irrelevant here.
bowcaster(ct) := {"claims": {
	"platformCertificate": {"deviceIdentityManifest": {
		"googleIdentityDigest": "sOtCETvIpuc8I2CTkQxLT4YGfNHZocAvayRlmH6sC36x1+XtoNTHAYphxzRFsHIo",
		"intelIdentityDigest": "40LKtc7RowsVI32g9e7PnBKN6skdgAyYclPu5ZvQVNwFM9s8gQIR0r51fE11Uf7O",
	}},
	"certificateTransparency": ct,
}}

# A confidential VM's certificate binds Intel + NVIDIA identities but no Titan one.
confidential_vm(ct) := {"claims": {
	"platformCertificate": {"deviceIdentityManifest": {"intelIdentityDigest": "40LKtc7RowsVI32g9e7PnBKN6skdgAyYclPu5ZvQVNwFM9s8gQIR0r51fE11Uf7O"}},
	"certificateTransparency": ct,
}}

expired_ct := {
	"verified": true,
	"expiresAt": "2000-06-17T10:40:00-07:00", # WARNING: TEST WILL BREAK in ~100 years
}

ct_violation := "certificateTransparency claim is missing, unverified, or expired"

test_certificate_valid if {
	transparency.certificate_valid with time.now_ns as 0 # beginning of the universe
		with input as bowcaster(expired_ct)
}

test_certificate_expired if {
	not transparency.certificate_valid with time.now_ns as 1817185100000000000
		with input as bowcaster(expired_ct)
}

# Off-Bowcaster the claim is not required at all.
test_empty_certificate_valid if {
	transparency.certificate_valid with input as {"claims": {}}
}

test_no_violation_certificate_missing if {
	violations := transparency.violation with input as {"claims": {}}
	not ct_violation in violations
}

test_violation_certificate_expired if {
	violations := transparency.violation with time.now_ns as 1817185100000000000
		with input as bowcaster(expired_ct)
	ct_violation in violations
}

# On Bowcaster the claim is mandatory: a bundle that simply omits it is rejected, so
# enforcement doesn't rest on the claims generator always minting one.
test_certificate_missing_rejected_on_bowcaster if {
	input_without_ct := {"claims": {"platformCertificate": {"deviceIdentityManifest": {"googleIdentityDigest": "sOtCETvIpuc8I2CTkQxLT4YGfNHZocAvayRlmH6sC36x1+XtoNTHAYphxzRFsHIo"}}}}

	not transparency.certificate_valid with input as input_without_ct

	violations := transparency.violation with input as input_without_ct
	ct_violation in violations
}

# ---- Bowcaster scoping ----

test_bowcaster_requires_google_identity_digest if {
	transparency.bowcaster with input as bowcaster(expired_ct)
	not transparency.bowcaster with input as confidential_vm(expired_ct)

	# An explicit null digest, and an unverifiable chain (no manifest at all), are both
	# non-Bowcaster — the latter is already rejected by platformcertificate.valid_root.
	not transparency.bowcaster with input as {"claims": {"platformCertificate": {"deviceIdentityManifest": {"googleIdentityDigest": null}}}}
	not transparency.bowcaster with input as {"claims": {"platformCertificate": {"deviceIdentityManifest": null}}}
	not transparency.bowcaster with input as {"claims": {}}
}

# A node with no Titan identity in its certificate has no logged certificate, so an
# unverified/stale CT claim is neither a rejection nor a violation.
test_certificate_expired_ignored_without_google_identity if {
	transparency.certificate_valid with time.now_ns as 1817185100000000000
		with input as confidential_vm(expired_ct)

	violations := transparency.violation with time.now_ns as 1817185100000000000
		with input as confidential_vm(expired_ct)
	not ct_violation in violations
}

test_certificate_unverified_ignored_without_google_identity if {
	transparency.certificate_valid with time.now_ns as 0
		with input as confidential_vm({"verified": false, "expiresAt": "2200-01-02T00:00:00Z"})
}

# ---- Certificate-transparency log-head freshness ----

# Opportunistic during CT rollout: no binding present ⇒ fresh.
test_loghead_fresh_when_unbound if {
	transparency.certificate_loghead_fresh with input as bowcaster({"verified": true})
}

test_loghead_fresh_recent if {
	ts := "2026-07-12T00:00:00Z"
	transparency.certificate_loghead_fresh with time.now_ns as time.parse_rfc3339_ns(ts)
		with input as bowcaster({
			"logHeadDigestBound": true,
			"logHeadTimestamp": ts,
		})
}

test_loghead_stale_rejected if {
	ts := "2026-07-12T00:00:00Z"
	stale_now := time.parse_rfc3339_ns(ts) + 259200000000001 # 72h + 1ns
	stale := {"logHeadDigestBound": true, "logHeadTimestamp": ts}

	not transparency.certificate_loghead_fresh with time.now_ns as stale_now
		with input as bowcaster(stale)

	violations := transparency.violation with time.now_ns as stale_now
		with input as bowcaster(stale)
	"certificateTransparency log head is stale or missing a quote-bound timestamp" in violations
}

# Log-head freshness is NOT scoped to Bowcaster: whoever binds a log head must bind a
# fresh one, so the same stale head is rejected without a Titan identity too.
test_loghead_stale_rejected_without_google_identity if {
	ts := "2026-07-12T00:00:00Z"
	stale_now := time.parse_rfc3339_ns(ts) + 259200000000001
	stale := {"logHeadDigestBound": true, "logHeadTimestamp": ts}

	not transparency.certificate_loghead_fresh with time.now_ns as stale_now
		with input as confidential_vm(stale)

	violations := transparency.violation with time.now_ns as stale_now
		with input as confidential_vm(stale)
	"certificateTransparency log head is stale or missing a quote-bound timestamp" in violations
}

# Binding claimed but no timestamp (digest didn't match the carried SLH) ⇒ rejected.
test_loghead_bound_without_timestamp_rejected if {
	not transparency.certificate_loghead_fresh with time.now_ns as 0
		with input as bowcaster({"logHeadDigestBound": true})
}
