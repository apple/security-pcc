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

package gcpv1.binding

import data.gcpv1.host
import data.gcpv1.keyprotection
import data.gcpv1.workload

claims := input.claims

### ---- Workload <-> KeyProtection VM consistency (shared by both `valid` paths below)
base_valid if {
	workload.valid
	keyprotection.valid
	claims.protobuf.workloadBindingPublicKey != null
	claims.protobuf.workloadBindingPublicKey == claims.protobuf.keyProtectionBindingPublicKey
	claims.workloadPCK.platformInstanceID != null
	claims.workloadPCK.platformInstanceID == claims.keyProtectionPCK.platformInstanceID
	claims.workloadTDX.mrtd != null
	claims.workloadTDX.mrtd == claims.keyProtectionTDX.mrtd
	metadata_bound
}

# AttestedMetadata (nonce / appData / certificate-transparency log-head digest) must be the bytes
# bound into the TDX quote: its SHA256 has to equal the workload challenge. The challenge is only
# pinned to the quote once `workload.valid` holds (it reconciles the quote's REPORTDATA against a
# verified quote), so we require that here too — otherwise this rule would merely assert equality of
# two self-reported fields. An empty AttestedMetadata is still bound, since the challenge is SHA256("").
default metadata_bound := false

# METADATA
# entrypoint: true
metadata_bound if {
	workload.valid
	claims.protobuf.attestedMetadataDigest == claims.protobuf.workloadChallenge
}

# Legacy path: machines with no Titan host attestation validate on the
# workload<->keyProtection VM binding alone.
valid if {
	not claims.hostCSEL
	base_valid
}

### ---- Workload <-> KeyProtection <-> Host consistency
#
# Bare-metal hosts with a Titan host attestation additionally measure a CPU
# Platform Instance ID (`hostCSEL.cpuPIID`) that must match the Intel PCK
# certificate's `platformInstanceID` carried by both VMs — binding the VM
# attestations to the specific physical host the Titan attested.
valid if {
	claims.hostCSEL
	host.valid
	base_valid
	claims.hostCSEL.cpuPIID != null
	claims.hostCSEL.cpuPIID == claims.workloadPCK.platformInstanceID
	claims.hostCSEL.cpuPIID == claims.keyProtectionPCK.platformInstanceID
}

# ---- Binding diagnostics ----
#
# `# METADATA / # entrypoint: true` on the first clause keeps `opa build
# --target plan` from dead-code-eliminating the whole `violation` set when
# its only references are cross-package (from `gcpv1.all_violations`).

# METADATA
# entrypoint: true
violation contains "protobuf.workloadBindingPublicKey is null" if {
	claims.protobuf
	claims.protobuf.workloadBindingPublicKey == null
}

violation contains "protobuf.workloadBindingPublicKey does not match protobuf.keyProtectionBindingPublicKey" if {
	claims.protobuf.workloadBindingPublicKey
	claims.protobuf.workloadBindingPublicKey != claims.protobuf.keyProtectionBindingPublicKey
}

violation contains "workloadPCK.platformInstanceID is null" if {
	claims.workloadPCK
	claims.workloadPCK.platformInstanceID == null
}

violation contains "workloadPCK.platformInstanceID does not match keyProtectionPCK.platformInstanceID" if {
	claims.workloadPCK.platformInstanceID
	claims.workloadPCK.platformInstanceID != claims.keyProtectionPCK.platformInstanceID
}

violation contains "workloadTDX.mrtd is null" if {
	claims.workloadTDX
	claims.workloadTDX.mrtd == null
}

violation contains "workloadTDX.mrtd does not match keyProtectionTDX.mrtd" if {
	claims.workloadTDX.mrtd
	claims.workloadTDX.mrtd != claims.keyProtectionTDX.mrtd
}

violation contains "protobuf.attestedMetadataDigest does not match protobuf.workloadChallenge" if {
	claims.protobuf.attestedMetadataDigest
	claims.protobuf.attestedMetadataDigest != claims.protobuf.workloadChallenge
}

violation contains "host attestation present but hostTPM/host/hostCSEL do not reconcile" if {
	claims.hostCSEL
	not host.valid
}

violation contains "hostCSEL.cpuPIID does not match workloadPCK.platformInstanceID" if {
	claims.hostCSEL.cpuPIID
	claims.hostCSEL.cpuPIID != claims.workloadPCK.platformInstanceID
}

violation contains "hostCSEL.cpuPIID does not match keyProtectionPCK.platformInstanceID" if {
	claims.hostCSEL.cpuPIID
	claims.hostCSEL.cpuPIID != claims.keyProtectionPCK.platformInstanceID
}
