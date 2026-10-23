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

package gcpv1.metadata

claims := input.claims

# Reconciliation of the caller-attached metadata envelope with the signed quotes.
#
# At attestation time the challenge signed into every TDX/host quote is
# `SHA256(serialized AttestedMetadata{nonce, appData})` — computed even when the
# caller attached nothing, since an empty envelope still hashes to a fixed digest.
# The generator therefore always surfaces that digest as
# `protobuf.attestedMetadataDigest` and the caller's nonce as
# `protobuf.attestedNonce`. Here we bind:
#
#  1. every present quote challenge == attestedMetadataDigest, so the `nonce` +
#     `appData` the caller attached (or their absence) are authenticated by the
#     hardware quotes. Because the digest is taken over the exact bytes carried in
#     the bundle, stripping or tampering with `attested_metadata` changes the
#     digest and breaks this binding — the envelope cannot be dropped undetected.
#  2. the attested nonce == the caller's expected nonce (`input.nonce`), when the
#     caller supplied one via ValidatorOptions.
#
# Only the nonce binding relaxes, and only when `input.nonce` is absent (the caller
# expressed no freshness expectation). The digest binding never relaxes: the digest
# is always present, and the TDX workload/key-protection quotes are mandatory, so
# their challenges are always enforced. The single exception is the optional host
# quote, whose challenge is skipped only when the bundle carries no host
# attestation. Because the digest pins the whole envelope (nonce + appData), the
# caller's `appData` is authenticated regardless of whether an expected nonce is
# supplied — there is deliberately no `input.appData` lever.

default valid := false

valid if {
	metadata_digest_reconciles
	nonce_reconciles
}

# --- attestedMetadataDigest <-> quote challenges ---

# The digest is always present; every present quote challenge must equal it.
metadata_digest_reconciles if {
	workload_challenge_matches
	key_protection_challenge_matches
	host_challenge_matches
}

# The TDX workload and key-protection quotes are always present, so their
# challenges are always enforced against the digest.
workload_challenge_matches if claims.protobuf.workloadChallenge == claims.protobuf.attestedMetadataDigest

key_protection_challenge_matches if claims.protobuf.keyProtectionChallenge == claims.protobuf.attestedMetadataDigest

# The host quote is optional (absent on non-bare-metal bundles). Enforce its
# challenge only when a host attestation contributed one.
host_challenge_matches if not claims.protobuf.hostChallenge
host_challenge_matches if claims.protobuf.hostChallenge == claims.protobuf.attestedMetadataDigest

# --- attested nonce <-> caller-expected nonce ---

# Relaxed: the caller supplied no expected nonce.
nonce_reconciles if {
	not input.nonce
}

# Enforced: the attested nonce must equal the caller's expected nonce.
nonce_reconciles if {
	input.nonce
	claims.protobuf.attestedNonce == input.nonce
}

# ---- Metadata diagnostics ----
#
# `# METADATA / # entrypoint: true` on the first clause keeps `opa build
# --target plan` from dead-code-eliminating the whole `violation` set when its
# only references are cross-package (from `gcpv1.all_violations`).

# METADATA
# entrypoint: true
violation contains "protobuf.workloadChallenge does not match protobuf.attestedMetadataDigest" if {
	claims.protobuf.workloadChallenge != claims.protobuf.attestedMetadataDigest
}

violation contains "protobuf.keyProtectionChallenge does not match protobuf.attestedMetadataDigest" if {
	claims.protobuf.keyProtectionChallenge != claims.protobuf.attestedMetadataDigest
}

violation contains "protobuf.hostChallenge does not match protobuf.attestedMetadataDigest" if {
	claims.protobuf.hostChallenge
	claims.protobuf.hostChallenge != claims.protobuf.attestedMetadataDigest
}

violation contains "protobuf.attestedNonce does not match expected input.nonce" if {
	input.nonce
	claims.protobuf.attestedNonce != input.nonce
}
