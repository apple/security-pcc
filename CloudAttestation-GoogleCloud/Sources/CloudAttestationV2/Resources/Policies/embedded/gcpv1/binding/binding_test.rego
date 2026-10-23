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

package gcpv1.binding_test

import data.gcpv1.binding
import data.gcpv1.host
import data.gcpv1.keyprotection
import data.gcpv1.workload

claims := {
	"protobuf": {
		"workloadBindingPublicKey": "somePublicKey",
		"keyProtectionBindingPublicKey": "somePublicKey",
		"attestedMetadataDigest": "bound-metadata-digest",
		"workloadChallenge": "bound-metadata-digest",
	},
	"workloadPCK": {"platformInstanceID": "2FC7F06E-5DB5-459B-BDC8-36FF1BCA76C5"},
	"keyProtectionPCK": {"platformInstanceID": "2FC7F06E-5DB5-459B-BDC8-36FF1BCA76C5"},
	"workloadTDX": {"mrtd": "some-mrtd-base64-value"},
	"keyProtectionTDX": {"mrtd": "some-mrtd-base64-value"},
}

test_binding_valid if {
	binding.valid with workload.valid as true
		with keyprotection.valid as true
		with input as {"claims": claims}
}

test_violation_binding_pubkey_mismatch if {
	violations := binding.violation with input as {"claims": object.union(claims, {"protobuf": {
		"workloadBindingPublicKey": "abc",
		"keyProtectionBindingPublicKey": "xyz",
	}})}
	"protobuf.workloadBindingPublicKey does not match protobuf.keyProtectionBindingPublicKey" in violations
}

test_violation_binding_mrtd_null if {
	violations := binding.violation with input as {"claims": object.union(claims, {"workloadTDX": {"mrtd": null}})}
	"workloadTDX.mrtd is null" in violations
}

# ---- Host <-> VM Platform Instance ID consistency ----
#
# Older machines carry no host attestation at all (no `hostCSEL` claim); the
# base `claims` fixture above has none, and `test_binding_valid` already
# proves that case is a no-op. These cover the bare-metal case explicitly.

claims_with_host := object.union(claims, {"hostCSEL": {"cpuPIID": "2FC7F06E-5DB5-459B-BDC8-36FF1BCA76C5"}})

test_binding_valid_with_matching_host_piid if {
	binding.valid with workload.valid as true
		with keyprotection.valid as true
		with host.valid as true
		with input as {"claims": claims_with_host}
}

test_violation_host_piid_mismatch_workload if {
	mismatched := object.union(claims_with_host, {"hostCSEL": {"cpuPIID": "different-piid"}})
	violations := binding.violation with host.valid as true
		with input as {"claims": mismatched}
	"hostCSEL.cpuPIID does not match workloadPCK.platformInstanceID" in violations
	"hostCSEL.cpuPIID does not match keyProtectionPCK.platformInstanceID" in violations
}

test_violation_host_present_but_not_reconciled if {
	violations := binding.violation with host.valid as false
		with input as {"claims": claims_with_host}
	"host attestation present but hostTPM/host/hostCSEL do not reconcile" in violations
}

test_binding_invalid_when_host_piid_mismatches if {
	mismatched := object.union(claims_with_host, {"hostCSEL": {"cpuPIID": "different-piid"}})
	not binding.valid with workload.valid as true
		with keyprotection.valid as true
		with host.valid as true
		with input as {"claims": mismatched}
}

# An empty `{}` object is truthy in Rego, so empty host sections read as a real
# host attestation and get rejected for failing reconciliation — the generator
# must omit host claims entirely (not emit `{}`) when there is no host quote.
empty_host_sections := object.union(claims, {"host": {}, "hostCSEL": {}, "hostTPM": {}})

test_empty_host_sections_read_as_present_and_reject if {
	not binding.valid with workload.valid as true
		with keyprotection.valid as true
		with input as {"claims": empty_host_sections}

	violations := binding.violation with input as {"claims": empty_host_sections}
	"host attestation present but hostTPM/host/hostCSEL do not reconcile" in violations
}

test_no_host_sections_take_legacy_path if {
	binding.valid with workload.valid as true
		with keyprotection.valid as true
		with input as {"claims": claims}

	violations := binding.violation with input as {"claims": claims}
	not "host attestation present but hostTPM/host/hostCSEL do not reconcile" in violations
}

# ---- AttestedMetadata <-> quote binding ----
#
# The base `claims` fixture carries a matching `attestedMetadataDigest`/`workloadChallenge` pair, so
# `test_binding_valid` already exercises the bound case. These cover the mismatch.

unbound_metadata := object.union(claims, {"protobuf": object.union(claims.protobuf, {
	"attestedMetadataDigest": "c2hhMjU2LW9mLW1ldGFkYXRh",
	"workloadChallenge": "c29tZS1vdGhlci1jaGFsbGVuZ2U",
})})

test_binding_invalid_when_metadata_not_bound if {
	not binding.valid with workload.valid as true
		with keyprotection.valid as true
		with input as {"claims": unbound_metadata}
}

test_violation_metadata_not_bound if {
	violations := binding.violation with input as {"claims": unbound_metadata}
	"protobuf.attestedMetadataDigest does not match protobuf.workloadChallenge" in violations
}

test_no_violation_when_metadata_bound if {
	violations := binding.violation with input as {"claims": claims}
	not "protobuf.attestedMetadataDigest does not match protobuf.workloadChallenge" in violations
}
