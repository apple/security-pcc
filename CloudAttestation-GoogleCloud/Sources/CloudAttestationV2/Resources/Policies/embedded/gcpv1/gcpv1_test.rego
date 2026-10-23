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

package gcpv1_test

import data.gcpv1

test_valid_development if {
	gcpv1.valid.development with input as {"claims": claims}
}

test_valid_qa if {
	gcpv1.valid.qa with time.now_ns as 0
		with input as {
			"claims": object.union(claims, transparency_verified),
			"environment": "qa",
		}
}

test_valid_production if {
	gcpv1.valid.production with time.now_ns as 0
		with input as {
			"claims": object.union(claims, transparency_verified),
			"environment": "production",
		}
}

test_simulator_attestation_claims if {
	gcpv1.release_structure_valid with time.now_ns as 0
		with input as {"claims": simulator_claims}
}

# ---- Platform-certificate gating per environment ----

transparency_verified := {
	"softwareTransparency": {
		"verified": true,
		"expiresAt": "2000-06-17T10:40:00-07:00",
	},
	"firmwareTransparency": {
		"verified": true,
		"expiresAt": "2000-06-17T10:40:00-07:00",
	},
}

# QA and production both pin the platform-certificate root, so a bundle carrying
# no platform cert at all cannot pass — even with everything else in order.
test_qa_invalid_without_platform_certificate if {
	stripped := object.remove(object.union(claims, transparency_verified), ["platformCertificate"])

	not gcpv1.valid.qa with time.now_ns as 0 with input as {"claims": stripped, "environment": "qa"}
	"platformCertificate claim is missing" in gcpv1.decision.violations with time.now_ns as 0
		with input as {"claims": stripped, "environment": "qa"}
}

# The DCA test root and the self-signed dev CA are development-only: an otherwise
# perfect bundle rooted in either must fail both qa and production.
test_qa_and_production_reject_development_only_roots if {
	some root in [
		{
			"subject": "C=US,ST=California,O=Apple Inc.,CN=Test Data Center Attestation Online Root CA - G3",
			"fingerprint": "mQfMsJLNEHpUBlYYwaP8g6/olKvrKqllQySJtUfRth8u2XAVYcUy0itsJjYWFkhD",
		},
		{
			"subject": "CN=CloudAttestationV2 Dev CA",
			"fingerprint": "27u0po3jS5tTu9nIQVrxVN/q1EcPuQRgGfxy/BlcxpGJ1QW88lqwDdOj9ZYcFqdS",
		},
	]

	rerooted := object.union(object.union(claims, transparency_verified), {"platformCertificate": object.union(
		claims.platformCertificate,
		{
			"trustChainSubjects": [root.subject],
			"trustChainFingerprints": [root.fingerprint],
		},
	)})

	not gcpv1.valid.qa with time.now_ns as 0 with input as {"claims": rerooted, "environment": "qa"}
	not gcpv1.valid.production with time.now_ns as 0 with input as {"claims": rerooted, "environment": "production"}
}

# Both environments bind the cert's manifest to the live evidence: a stale or mis-issued
# certificate from another node must not pass on root pinning alone.
test_qa_and_production_reject_manifest_mismatch if {
	mismatched := object.union(
		object.union(claims, transparency_verified),
		{"computedDeviceIdentityManifest": {"intelIdentityDigest": "a-different-pck-digest"}},
	)

	not gcpv1.valid.qa with time.now_ns as 0 with input as {"claims": mismatched, "environment": "qa"}
	not gcpv1.valid.production with time.now_ns as 0 with input as {"claims": mismatched, "environment": "production"}

	decision := gcpv1.decision with time.now_ns as 0
		with input as {"claims": mismatched, "environment": "production"}
	decision.allow == false
	some v in decision.violations
	startswith(v, "platformCertificate.deviceIdentityManifest ")
}

# ---- Aggregated decision.violations tests ----

# Valid claims => empty violations array. (Even with no `valid[environment]`
# rule firing, no per-module violation rules should fire either.)
test_decision_violations_empty_when_valid if {
	decision := gcpv1.decision with time.now_ns as 0
		with input as {
			"claims": object.union(claims, {
				"softwareTransparency": {
					"verified": true,
					"expiresAt": "2000-06-17T10:40:00-07:00",
				},
				"firmwareTransparency": {
					"verified": true,
					"expiresAt": "2000-06-17T10:40:00-07:00",
				},
			}),
			"environment": "qa",
		}
	decision.allow == true
	count(decision.violations) == 0
}

# Aggregation fires per-module rules and dedups via set union; results are sorted.
test_decision_violations_aggregates_modules if {
	decision := gcpv1.decision with time.now_ns as 0
		with input as {
			"claims": object.union(claims, {
				# break workload (rtmr0 mismatch), binding (mrtd mismatch),
				# transparency (missing software/firmware claims).
				"workloadCCEL": object.union(ccel_claims, {"replayedRTMR0": "BAD"}),
				"keyProtectionTDX": object.union(tdx_claims, {"mrtd": "DIFFERENT-MRTD"}),
			}),
			"environment": "qa",
		}
	decision.allow == false
	"workloadCCEL.replayedRTMR0 does not match workloadTDX.rtmr0" in decision.violations
	"workloadTDX.mrtd does not match keyProtectionTDX.mrtd" in decision.violations
	"softwareTransparency claim is missing, unverified, or expired" in decision.violations
	"firmwareTransparency claim is missing, unverified, or expired" in decision.violations
}

tdx_claims := {
	"verified": true,
	"reportData": "some-base64-sha512-digest",
	"tdAttributes": {
		"debug": false,
		"septVeDisable": true,
		"migratable": false,
		"pks": false,
		"perfMon": false,
		"kl": false,
	},
	"xfam": {
		"pt": false,
		"lbr": false,
	},
	"seamAttributes": "AAAAAAAAAAA=",
	"qeAttributes": {
		"initialized": true,
		"debug": false,
		"mode64Bit": true,
	},
	"mrtd": "some-mrtd-value",
	"rtmr0": "some-base64-sha384-digest-0",
	"rtmr1": "some-base64-sha384-digest-1",
	"rtmr2": "some-base64-sha384-digest-2",
	"rtmr3": "some-base64-sha384-digest-3",
}

ccel_claims := {
	"replayedRTMR0": "some-base64-sha384-digest-0",
	"replayedRTMR1": "some-base64-sha384-digest-1",
	"replayedRTMR2": "some-base64-sha384-digest-2",
	"secureBoot": {
		"uefiDebugMode": false,
		"dmaProtectionDisabled": false,
	},
	"efiApplications": [
		"some-shim",
		"some-grub",
	],
	"kernel": {},
}

csel_claims := {
	"replayedMeasurements": {"sha384": "some-base64-sha384-digest-3"},
	"gpus": [
		{"attestation": "some-base64-gpu-attestation", "driverVersion": "590.48.01", "vbiosVersion": "97.00.D9.00.35", "architecture": "blackwell"},
		{"attestation": "some-base64-gpu-attestation", "driverVersion": "590.48.01", "vbiosVersion": "97.00.D9.00.35", "architecture": "blackwell"},
		{"attestation": "some-base64-gpu-attestation", "driverVersion": "590.48.01", "vbiosVersion": "97.00.D9.00.35", "architecture": "blackwell"},
		{"attestation": "some-base64-gpu-attestation", "driverVersion": "590.48.01", "vbiosVersion": "97.00.D9.00.35", "architecture": "blackwell"},
		{"attestation": "some-base64-gpu-attestation", "driverVersion": "590.48.01", "vbiosVersion": "97.00.D9.00.35", "architecture": "blackwell"},
		{"attestation": "some-base64-gpu-attestation", "driverVersion": "590.48.01", "vbiosVersion": "97.00.D9.00.35", "architecture": "blackwell"},
		{"attestation": "some-base64-gpu-attestation", "driverVersion": "590.48.01", "vbiosVersion": "97.00.D9.00.35", "architecture": "blackwell"},
		{"attestation": "some-base64-gpu-attestation", "driverVersion": "590.48.01", "vbiosVersion": "97.00.D9.00.35", "architecture": "blackwell"},
	],
	"containerImageDigest": "some-base64-container-image-sha384",
}

gpu_claims := [
	{"verified": true, "nonce": "some-base64-nonce", "driverMeasurement": {"product": "GB100", "version": "590.48.01", "blocks": [{"index": 15, "digest": "some-base64-block-digest"}]}, "vbiosMeasurement": {"product": "GB100", "version": "97.00.D9.00.35", "blocks": [{"index": 1, "digest": "some-base64-block-digest"}]}},
	{"verified": true, "nonce": "some-base64-nonce", "driverMeasurement": {"product": "GB100", "version": "590.48.01", "blocks": [{"index": 15, "digest": "some-base64-block-digest"}]}, "vbiosMeasurement": {"product": "GB100", "version": "97.00.D9.00.35", "blocks": [{"index": 1, "digest": "some-base64-block-digest"}]}},
	{"verified": true, "nonce": "some-base64-nonce", "driverMeasurement": {"product": "GB100", "version": "590.48.01", "blocks": [{"index": 15, "digest": "some-base64-block-digest"}]}, "vbiosMeasurement": {"product": "GB100", "version": "97.00.D9.00.35", "blocks": [{"index": 1, "digest": "some-base64-block-digest"}]}},
	{"verified": true, "nonce": "some-base64-nonce", "driverMeasurement": {"product": "GB100", "version": "590.48.01", "blocks": [{"index": 15, "digest": "some-base64-block-digest"}]}, "vbiosMeasurement": {"product": "GB100", "version": "97.00.D9.00.35", "blocks": [{"index": 1, "digest": "some-base64-block-digest"}]}},
	{"verified": true, "nonce": "some-base64-nonce", "driverMeasurement": {"product": "GB100", "version": "590.48.01", "blocks": [{"index": 15, "digest": "some-base64-block-digest"}]}, "vbiosMeasurement": {"product": "GB100", "version": "97.00.D9.00.35", "blocks": [{"index": 1, "digest": "some-base64-block-digest"}]}},
	{"verified": true, "nonce": "some-base64-nonce", "driverMeasurement": {"product": "GB100", "version": "590.48.01", "blocks": [{"index": 15, "digest": "some-base64-block-digest"}]}, "vbiosMeasurement": {"product": "GB100", "version": "97.00.D9.00.35", "blocks": [{"index": 1, "digest": "some-base64-block-digest"}]}},
	{"verified": true, "nonce": "some-base64-nonce", "driverMeasurement": {"product": "GB100", "version": "590.48.01", "blocks": [{"index": 15, "digest": "some-base64-block-digest"}]}, "vbiosMeasurement": {"product": "GB100", "version": "97.00.D9.00.35", "blocks": [{"index": 1, "digest": "some-base64-block-digest"}]}},
	{"verified": true, "nonce": "some-base64-nonce", "driverMeasurement": {"product": "GB100", "version": "590.48.01", "blocks": [{"index": 15, "digest": "some-base64-block-digest"}]}, "vbiosMeasurement": {"product": "GB100", "version": "97.00.D9.00.35", "blocks": [{"index": 1, "digest": "some-base64-block-digest"}]}},
]

device_identity_manifest := {
	"intelIdentityDigest": "some-base64-sha384-pck-digest",
	"nvidiaIdentityDigest": ["some-base64-sha384-gpu-leaf-digest"],
}

claims := {
	"workloadTDX": tdx_claims,
	"workloadCCEL": ccel_claims,
	"workloadCSEL": csel_claims,
	"workloadGPUs": gpu_claims,
	"keyProtectionTDX": tdx_claims,
	"keyProtectionCCEL": ccel_claims,
	"protobuf": {
		"workloadReportDataDigest": "some-base64-sha512-digest",
		"keyProtectionReportDataDigest": "some-base64-sha512-digest",
		"workloadBindingPublicKey": "some-binding-public-key",
		"keyProtectionBindingPublicKey": "some-binding-public-key",
		"attestedMetadataDigest": "some-base64-attested-metadata-digest",
		"workloadChallenge": "some-base64-attested-metadata-digest",
		"keyProtectionChallenge": "some-base64-attested-metadata-digest",
	},
	"platformCertificate": {
		"verified": true,
		"trustChainSubjects": ["C=US,ST=California,O=Apple Inc.,CN=Data Center Attestation Online Root CA - G3"],
		"trustChainFingerprints": ["HC9ftZcf2Z0a6/YYGTrNFF0LJNcMX94pg21QPPDeN2feUmf7q+SoJRyjFh+3etG/"],
		"deviceIdentityManifest": device_identity_manifest,
	},
	"computedDeviceIdentityManifest": device_identity_manifest,
	"workloadPCK": {"platformInstanceID": "BC24CAD9-18AB-458D-B603-02513BC796B4"},
	"keyProtectionPCK": {"platformInstanceID": "BC24CAD9-18AB-458D-B603-02513BC796B4"},
	"output": {
		"publicKey": "der-encoded-publicKey",
		"expiration": "2000-06-17T10:40:00-07:00",
	},
}

simulator_claims := {
	"firmwareTransparency": {
		"digest": "A2F2EAPS4eYnKxtEO5NQMjTK9rzhVehUi+7q9fKsuZY=",
		"expiresAt": "2200-01-02T00:00:00Z",
		"verified": true,
	},
	"generator": "Generator",
	"keyProtectionCCEL": {
		"efiApplications": [
			{"digest": "bD0iqJAMGG28sUjrnwTx2YpvH1hfpmgrKkM+9vB9i0EmrqlcxxNpxl79\/tYi89P+"},
			{"digest": "kMbIyhWmSE3sUpoxqAZ+b6deuyFBGEn058TW8jA\/+C3vQvXOnkkrHNwgoVAVXszU"},
		],
		"kernel": {
			"cmdline": "BOOT_IMAGE=\/vmlinuz root=\/dev\/sda1 ro",
			"imageDigest": "\/kOEGQXoMXx0G7rQi9GwlgvhhKHg5JHQijaGBRZ44JzLd0sUNm1y1jGIHQTSKqes",
			"untrustedImagePath": "\/vmlinuz-mock",
		},
		"replayedRTMR0": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		"replayedRTMR1": "n0H5lHHtna94nrx84dN2G7xshNOn0MvBZydR4S8VVmJ4EVuUHnP10N86f0dbu06y",
		"replayedRTMR2": "XzsI+7U5lvFEwHZ4YV63GgIbWAfAjnKxyYxZm6iIMNlJEasP53lFqZexUg4jjnuh",
	},
	"keyProtectionPCK": {"platformInstanceID": "u7u7u7u7u7u7u7u7u7u7uw=="},
	"keyProtectionTDX": {
		"fmspc": "kIBvAAAA",
		"mrConfigId": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		"mrOwner": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		"mrOwnerConfig": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		"mrSeam": "oaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGh",
		"mrSignerSeam": "oqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKi",
		"mrtd": "o6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Oj",
		"pcesvn": 13,
		"pckCertificate": "MIIDajCCAxCgAwIBAgIVAJvcnr6G86\/qkthwOBVFGfH6eZedMAoGCCqGSM49BAMCMCcxJTAjBgNVBAMMHFdTRFNpbXVsYXRvciBNb2NrIFBDSyBJc3N1ZXIwHhcNMjMxMTE0MjIxMzIwWhcNMjQxMTEzMjIxMzIwWjAlMSMwIQYDVQQDDBpXU0RTaW11bGF0b3IgTW9jayBQQ0sgTGVhZjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABJe\/v1QBPJmqSV7nGNZswdHPTTqUQmNlyJWAcpicM5OmB8KsPkE5TEa34umL\/zRnyKthOhUjFwjVP5wlm6eK3kKjggIZMIICFTAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB\/wQEAwIHgDCCAfMGCSqGSIb4TQENAQSCAeQwggHgMB4GCiqGSIb4TQENAQEEEKqqqqqqqqqqqqqqqqqqqqowggFjBgoqhkiG+E0BDQECMIIBUzAQBgsqhkiG+E0BDQECAQIBADAQBgsqhkiG+E0BDQECAgIBADAQBgsqhkiG+E0BDQECAwIBADAQBgsqhkiG+E0BDQECBAIBADAQBgsqhkiG+E0BDQECBQIBADAQBgsqhkiG+E0BDQECBgIBADAQBgsqhkiG+E0BDQECBwIBADAQBgsqhkiG+E0BDQECCAIBADAQBgsqhkiG+E0BDQECCQIBADAQBgsqhkiG+E0BDQECCgIBADAQBgsqhkiG+E0BDQECCwIBADAQBgsqhkiG+E0BDQECDAIBADAQBgsqhkiG+E0BDQECDQIBADAQBgsqhkiG+E0BDQECDgIBADAQBgsqhkiG+E0BDQECDwIBADAQBgsqhkiG+E0BDQECEAIBADAQBgsqhkiG+E0BDQECEQIBDTAfBgsqhkiG+E0BDQECEgQQAAAAAAAAAAAAAAAAAAAAADAQBgoqhkiG+E0BDQEDBAIAADAUBgoqhkiG+E0BDQEEBAaQgG8AAAAwDwYKKoZIhvhNAQ0BBQoBADAeBgoqhkiG+E0BDQEGBBC7u7u7u7u7u7u7u7u7u7u7MAoGCCqGSM49BAMCA0gAMEUCIQCAQxqtoi7moV3ZVuk3Rk05rGtCkBq0cUXQIhNZe9H6bAIgOy0eQp6t4yVi0qXmbc9OHkwtVWd09Q7yH6qq9\/mHw+8=",
		"qeAttributes": {
			"aexNotify": false,
			"cet": false,
			"debug": false,
			"einitTokenKey": false,
			"initialized": false,
			"kss": false,
			"mode64Bit": false,
			"provisionKey": false,
		},
		"qeISVProdId": 1,
		"qeISVSVN": 1,
		"qeMREnclave": "wcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcE=",
		"qeMRSigner": "wsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsI=",
		"reportData": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==",
		"rtmr0": "sLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCw",
		"rtmr1": "sbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGx",
		"rtmr2": "srKysrKysrKysrKysrKysrKysrKysrKysrKysrKysrKysrKysrKysrKysrKysrKy",
		"rtmr3": "s7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Oz",
		"seamAttributes": "AAAAAAAAAAA=",
		"sgxTcbCompSvn": "AAAAAAAAAAAAAAAAAAAAAA==",
		"tdAttributes": {
			"debug": false,
			"kl": false,
			"migratable": false,
			"perfMon": false,
			"pks": false,
			"septVeDisable": false,
		},
		"teeTcbSvn": "AAAAAAAAAAAAAAAAAAAAAA==",
		"verified": false,
		"xfam": {
			"cetS": false,
			"cetU": false,
			"lbr": false,
			"prku": false,
			"pt": false,
		},
	},
	"output": {
		"expiration": "2026-06-17T23:51:47Z",
		"publicKey": {"curve25519": {"_0": "amTZOu\/OxWpzb\/ni1cpxiAoT4UDPA2OhoTMDe5aphVk="}},
	},
	"protobuf": {
		"keyProtectionBindingPublicKey": "amTZOu\/OxWpzb\/ni1cpxiAoT4UDPA2OhoTMDe5aphVk=",
		"keyProtectionReportDataDigest": "3mNQP2GrwyRGLvGlrBMMCxgad7CvIoQI8Vv6JdNJ1MWXWXAoVbXKdoieQJeYyrY\/aCbvnN3ng3GkD9iv5X8PhA==",
		"workloadBindingPublicKey": "amTZOu\/OxWpzb\/ni1cpxiAoT4UDPA2OhoTMDe5aphVk=",
		"workloadReportDataDigest": "XJeJ5JbFFP1yPmCQFuB6i6aY8C2x25AygYYb22O1+qCKY9DwXpbYeDbvCjAGgGbLYY2nJuj5SU+T1pa4yHT9vg==",
	},
	"softwareTransparency": {
		"digest": "kAFLg8DMWkt5eg\/3LYMQQmdPhNmVilwcEFnKILpbtOM=",
		"expiresAt": "2200-01-02T00:00:00Z",
		"verified": true,
	},
	"workloadCCEL": {
		"efiApplications": [
			{"digest": "bD0iqJAMGG28sUjrnwTx2YpvH1hfpmgrKkM+9vB9i0EmrqlcxxNpxl79\/tYi89P+"},
			{"digest": "kMbIyhWmSE3sUpoxqAZ+b6deuyFBGEn058TW8jA\/+C3vQvXOnkkrHNwgoVAVXszU"},
		],
		"kernel": {
			"cmdline": "BOOT_IMAGE=\/vmlinuz root=\/dev\/sda1 ro",
			"imageDigest": "\/kOEGQXoMXx0G7rQi9GwlgvhhKHg5JHQijaGBRZ44JzLd0sUNm1y1jGIHQTSKqes",
			"untrustedImagePath": "\/vmlinuz-mock",
		},
		"replayedRTMR0": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		"replayedRTMR1": "n0H5lHHtna94nrx84dN2G7xshNOn0MvBZydR4S8VVmJ4EVuUHnP10N86f0dbu06y",
		"replayedRTMR2": "XzsI+7U5lvFEwHZ4YV63GgIbWAfAjnKxyYxZm6iIMNlJEasP53lFqZexUg4jjnuh",
	},
	"workloadCSEL": {
		"containerImageDigest": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
		"environmentVariables": [{
			"name": "PCC_VARIANT",
			"value": "mock",
		}],
		"gpus": [],
		"pccVariant": "mock",
		"replayedMeasurements": {"sha384": "3IV1tFVFV0D+942EDk4OHGKvSmxd4hRlXzdvEwiC0RopzaYxS18oQx\/mKc+bWDKy"},
	},
	"workloadGPUs": [],
	"workloadPCK": {"platformInstanceID": "u7u7u7u7u7u7u7u7u7u7uw=="},
	"workloadTDX": {
		"fmspc": "kIBvAAAA",
		"mrConfigId": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		"mrOwner": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		"mrOwnerConfig": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		"mrSeam": "oaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGh",
		"mrSignerSeam": "oqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKi",
		"mrtd": "o6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Oj",
		"pcesvn": 13,
		"pckCertificate": "MIIDajCCAxCgAwIBAgIVAJvcnr6G86\/qkthwOBVFGfH6eZedMAoGCCqGSM49BAMCMCcxJTAjBgNVBAMMHFdTRFNpbXVsYXRvciBNb2NrIFBDSyBJc3N1ZXIwHhcNMjMxMTE0MjIxMzIwWhcNMjQxMTEzMjIxMzIwWjAlMSMwIQYDVQQDDBpXU0RTaW11bGF0b3IgTW9jayBQQ0sgTGVhZjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABJe\/v1QBPJmqSV7nGNZswdHPTTqUQmNlyJWAcpicM5OmB8KsPkE5TEa34umL\/zRnyKthOhUjFwjVP5wlm6eK3kKjggIZMIICFTAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB\/wQEAwIHgDCCAfMGCSqGSIb4TQENAQSCAeQwggHgMB4GCiqGSIb4TQENAQEEEKqqqqqqqqqqqqqqqqqqqqowggFjBgoqhkiG+E0BDQECMIIBUzAQBgsqhkiG+E0BDQECAQIBADAQBgsqhkiG+E0BDQECAgIBADAQBgsqhkiG+E0BDQECAwIBADAQBgsqhkiG+E0BDQECBAIBADAQBgsqhkiG+E0BDQECBQIBADAQBgsqhkiG+E0BDQECBgIBADAQBgsqhkiG+E0BDQECBwIBADAQBgsqhkiG+E0BDQECCAIBADAQBgsqhkiG+E0BDQECCQIBADAQBgsqhkiG+E0BDQECCgIBADAQBgsqhkiG+E0BDQECCwIBADAQBgsqhkiG+E0BDQECDAIBADAQBgsqhkiG+E0BDQECDQIBADAQBgsqhkiG+E0BDQECDgIBADAQBgsqhkiG+E0BDQECDwIBADAQBgsqhkiG+E0BDQECEAIBADAQBgsqhkiG+E0BDQECEQIBDTAfBgsqhkiG+E0BDQECEgQQAAAAAAAAAAAAAAAAAAAAADAQBgoqhkiG+E0BDQEDBAIAADAUBgoqhkiG+E0BDQEEBAaQgG8AAAAwDwYKKoZIhvhNAQ0BBQoBADAeBgoqhkiG+E0BDQEGBBC7u7u7u7u7u7u7u7u7u7u7MAoGCCqGSM49BAMCA0gAMEUCIQCAQxqtoi7moV3ZVuk3Rk05rGtCkBq0cUXQIhNZe9H6bAIgOy0eQp6t4yVi0qXmbc9OHkwtVWd09Q7yH6qq9\/mHw+8=",
		"qeAttributes": {
			"aexNotify": false,
			"cet": false,
			"debug": false,
			"einitTokenKey": false,
			"initialized": false,
			"kss": false,
			"mode64Bit": false,
			"provisionKey": false,
		},
		"qeISVProdId": 1,
		"qeISVSVN": 1,
		"qeMREnclave": "wcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcE=",
		"qeMRSigner": "wsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsI=",
		"reportData": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==",
		"rtmr0": "sLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCw",
		"rtmr1": "sbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGx",
		"rtmr2": "srKysrKysrKysrKysrKysrKysrKysrKysrKysrKysrKysrKysrKysrKysrKysrKy",
		"rtmr3": "s7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Oz",
		"seamAttributes": "AAAAAAAAAAA=",
		"sgxTcbCompSvn": "AAAAAAAAAAAAAAAAAAAAAA==",
		"tdAttributes": {
			"debug": false,
			"kl": false,
			"migratable": false,
			"perfMon": false,
			"pks": false,
			"septVeDisable": false,
		},
		"teeTcbSvn": "AAAAAAAAAAAAAAAAAAAAAA==",
		"verified": false,
		"xfam": {
			"cetS": false,
			"cetU": false,
			"lbr": false,
			"prku": false,
			"pt": false,
		},
	},
}
