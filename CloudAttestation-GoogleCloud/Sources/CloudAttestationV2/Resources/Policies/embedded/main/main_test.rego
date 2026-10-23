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

package main_test

import data.gcpv1
import data.main

test_valid_decision_development if {
	main.decision.allow with input as {
		"environment": "development",
		"claims": claims,
	}
}

test_valid_decision_qa if {
	main.decision.allow with time.now_ns as 0
		with input as {
			"environment": "qa",
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
		}
}

test_valid_decision_production if {
	main.decision.allow with time.now_ns as 0
		with input as {
			"environment": "production",
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
		}
}

test_valid_decision_default_prod if {
	main.decision.allow with time.now_ns as 0
		with input as {"claims": object.union(claims, {
			"softwareTransparency": {
				"verified": true,
				"expiresAt": "2000-06-17T10:40:00-07:00",
			},
			"firmwareTransparency": {
				"verified": true,
				"expiresAt": "2000-06-17T10:40:00-07:00",
			},
		})}
}

# Bad bundle => decision.allow == false AND violations is non-empty.
# Mirrors the Swift `RegoPolicyEngine.handleDecision` rejection path in
# Tests/CloudAttestationV2Tests/OPATests.swift:basicPolicyRejectionReportsViolations.
test_decision_violations_surfaced_on_rejection if {
	decision := main.decision with time.now_ns as 0
		with input as {
			"environment": "qa",
			"claims": object.union(claims, {"workloadCCEL": object.union(ccel_claims, {"replayedRTMR0": "BAD"})}),
		}
	decision.allow == false
	count(decision.violations) > 0
	"workloadCCEL.replayedRTMR0 does not match workloadTDX.rtmr0" in decision.violations
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

# SPDM driver/VBIOS measurement shared by every GPU — the fleet must be
# homogeneous (see gpus.rego `homogeneous_gpu_measurements`).
gpu_measurement := {"product": "GB100", "version": "590.48.01", "blocks": [{"index": 15, "digest": "block-a"}]}

gpu_claims := [
	{"verified": true, "nonce": "some-base64-nonce", "driverMeasurement": gpu_measurement, "vbiosMeasurement": gpu_measurement},
	{"verified": true, "nonce": "some-base64-nonce", "driverMeasurement": gpu_measurement, "vbiosMeasurement": gpu_measurement},
	{"verified": true, "nonce": "some-base64-nonce", "driverMeasurement": gpu_measurement, "vbiosMeasurement": gpu_measurement},
	{"verified": true, "nonce": "some-base64-nonce", "driverMeasurement": gpu_measurement, "vbiosMeasurement": gpu_measurement},
	{"verified": true, "nonce": "some-base64-nonce", "driverMeasurement": gpu_measurement, "vbiosMeasurement": gpu_measurement},
	{"verified": true, "nonce": "some-base64-nonce", "driverMeasurement": gpu_measurement, "vbiosMeasurement": gpu_measurement},
	{"verified": true, "nonce": "some-base64-nonce", "driverMeasurement": gpu_measurement, "vbiosMeasurement": gpu_measurement},
	{"verified": true, "nonce": "some-base64-nonce", "driverMeasurement": gpu_measurement, "vbiosMeasurement": gpu_measurement},
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
