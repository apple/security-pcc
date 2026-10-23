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

package gcpv1.host

claims := input.claims

# Overall bare-metal host validity
default valid := false

valid if {
	claims.hostTPM.verified == true
	claims.hostTPM.extraData == claims.protobuf.hostChallenge
	claims.host.replayedPCR0 == claims.hostTPM.pcr0
	claims.host.replayedPCR17 == claims.hostTPM.pcr17
	claims.host.replayedPCR21 == claims.hostTPM.pcr21
	single_host_boot_image
	claims.hostCSEL.replayedMeasurements.sha256 == claims.hostTPM.pcr19
	warm_reset_counter_expected
}

# The host boots directly into a single UKI, so PCR[21] must carry exactly one
# boot-services application image. The release assembler binds only the first
# digest to the transparency-log release, so any extra image would be
# unattested; requiring `count == 1` here is the independent policy backstop.
single_host_boot_image if count(claims.host.bootApplicationDigests) == 1

# ---- Titan warm-reset counter (soft-reboot detection) ----
#
# Bowcaster's Titan TPM is electrically integrated with the CPU such that it
# reports, via the reserved NV index below, how many warm resets the CPU has
# undergone since the last power cycle. Nothing in the measured boot chain
# records a soft reboot — the PCRs replay identically either way — so this
# counter is the only evidence distinguishing a cleanly booted host from one
# warm-reset out from under a running workload.
#
# The expected value is a hard 2, fixed by contract with Google: Bowcaster's
# boot flow performs exactly two warm resets before the workload launches. Any
# other count is out of spec — so this is an equality check, deliberately not a
# bound, and the constant is not meant to be relaxed or made configurable.

# Reserved NV index for the counter: 0x01C10005. Rego has no hex literals.
warm_reset_counter_index := 29425669

# 8-byte big-endian 2, base64-encoded — the wire form of a `bytes` claim.
warm_reset_counter_expected_value := "AAAAAAAAAAI="

# The verified counter entries, if any. Only Bowcaster hosts (Titan TPM +
# auxiliary attestations) populate `hostAuxiliary`; on every other platform the
# claim is absent and this set is empty.
warm_reset_counters contains nv if {
	some nv in claims.hostAuxiliary.nvs
	nv.index == warm_reset_counter_index
}

# Gate for `valid`. Vacuously true when no auxiliary attestation is present, so
# non-Bowcaster hosts are unaffected; on Bowcaster it requires the counter to be
# both verified and exactly 2.
default warm_reset_counter_expected := false

warm_reset_counter_expected if not claims.hostAuxiliary

warm_reset_counter_expected if {
	claims.hostAuxiliary
	some nv in warm_reset_counters
	nv.verified == true
	nv.value == warm_reset_counter_expected_value
}

# ---- Host diagnostics ----
#
# `host` (boot log) and `hostCSEL` (CEL launch log, PCR[19]) are the bare-metal
# analogues of CCEL/CSEL, reconciled here against `hostTPM` (the TPM-quote
# analogue of TDX) exactly as `validate_ccel`/`workload.csel_valid` reconcile
# CCEL/CSEL against TDX's RTMRs. See HostClaims.swift's trust-model doc comment.
#
# `# METADATA / # entrypoint: true` on the first clause keeps `opa build
# --target plan` from dead-code-eliminating the whole `violation` set when its
# only references are cross-package (from `gcpv1.all_violations`).
#
# `hostTPM.verified` requires both the quoted PCR-map binding AND a Titan
# EK/DICE endorsement chain that verifies back to a pinned Google scribe root.
# Without it, hostTPM.pcr* / titanFirmwareDigest / titanDeviceIdentity are
# attacker-controlled.
#
# PCR[0] (H-CRTM platform firmware) is reconciled here too: it seeds the boot
# log's `bmcFirmwareDigest`, so without `replayedPCR0 == hostTPM.pcr0` a host on
# unpublished firmware could substitute a known-good BMC measurement into the
# unsigned log.

# METADATA
# entrypoint: true
violation contains "hostTPM not verified" if {
	claims.hostTPM
	claims.hostTPM.verified != true
}

# The signed quote nonce must equal the bundle's declared host challenge. Unlike
# TDX (which binds a `SHA256(label || ...)` report-data digest), real Titan host
# quotes carry the raw challenge in `TPMS_ATTEST.extraData` verbatim, so this is
# a direct byte comparison. `hostTPM.extraData` is only signature-bound once
# `hostTPM.verified` is true, so this reconciliation is meaningful only alongside
# the check above.
violation contains "hostTPM.extraData does not match protobuf.hostChallenge" if {
	claims.hostTPM
	claims.hostTPM.extraData != claims.protobuf.hostChallenge
}

violation contains "host.replayedPCR0 does not match hostTPM.pcr0" if {
	claims.host
	claims.hostTPM.pcr0 != claims.host.replayedPCR0
}

violation contains "host.replayedPCR17 does not match hostTPM.pcr17" if {
	claims.host
	claims.hostTPM.pcr17 != claims.host.replayedPCR17
}

violation contains "host.replayedPCR21 does not match hostTPM.pcr21" if {
	claims.host
	claims.hostTPM.pcr21 != claims.host.replayedPCR21
}

violation contains "hostCSEL.replayedMeasurements.sha256 does not match hostTPM.pcr19" if {
	claims.hostCSEL
	claims.hostTPM.pcr19 != claims.hostCSEL.replayedMeasurements.sha256
}

violation contains "host.bootApplicationDigests is not exactly one boot image" if {
	claims.host
	not single_host_boot_image
}

violation contains "hostCSEL.cpuPIID is null" if {
	claims.hostCSEL
	claims.hostCSEL.cpuPIID == null
}

# ---- Warm-reset counter diagnostics ----
#
# All three are guarded on `claims.hostAuxiliary`, so they only fire for
# Bowcaster hosts that actually carry auxiliary NV attestations.

# The counter entry must be present. A Bowcaster host that carries auxiliary
# attestations but omits this index has dropped the only soft-reboot evidence.
violation contains "hostAuxiliary is missing the Titan warm-reset counter" if {
	claims.hostAuxiliary
	count(warm_reset_counters) == 0
}

# The index label and value are attacker-controlled until the NV attestation's
# signature verifies, so an unverified counter carries no information.
violation contains msg if {
	claims.hostAuxiliary
	some nv in warm_reset_counters
	nv.verified != true
	msg := sprintf("hostAuxiliary warm-reset counter (NV %d) not verified", [warm_reset_counter_index])
}

# A verified counter reading anything other than 2 is out of spec: the host was
# warm-reset after provisioning, so the workload may be running on a
# soft-rebooted host.
violation contains msg if {
	claims.hostAuxiliary
	some nv in warm_reset_counters
	nv.verified == true
	nv.value != warm_reset_counter_expected_value
	msg := sprintf("hostAuxiliary warm-reset counter (NV %d) is out of spec: expected %v, got %v", [warm_reset_counter_index, warm_reset_counter_expected_value, nv.value])
}
