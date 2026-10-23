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

package gcpv1

import data.gcpv1.binding
import data.gcpv1.host
import data.gcpv1.keyprotection
import data.gcpv1.metadata
import data.gcpv1.platformcertificate
import data.gcpv1.transparency
import data.gcpv1.workload

claims := input.claims

default environment := "production"

environment := input.environment

default release_structure_valid := false

# METADATA
# entrypoint: true
release_structure_valid if {
	claims.output.publicKey
	claims.output.expiration
	claims.workloadTDX
	claims.workloadCCEL
	claims.workloadCSEL
	claims.keyProtectionTDX
	claims.keyProtectionCCEL
}

default baseline := false

baseline if {
	release_structure_valid
	claims.output.publicKey
	claims.output.expiration
	workload.valid
	keyprotection.valid
	binding.valid
	metadata.valid
}

valid["structural"] if {
	release_structure_valid
}

default valid["development"] := false

valid["development"] if {
	release_structure_valid
}

default valid["qa"] := false

valid["qa"] if {
	baseline
	platformcertificate.valid_root
	platformcertificate.manifest_valid

	transparency.valid
	transparency.certificate_loghead_fresh
}

default valid["production"] := false

valid["production"] if {
	baseline
	platformcertificate.valid_root
	platformcertificate.manifest_valid

	transparency.valid
	transparency.certificate_loghead_fresh
}

# ---- Envelope diagnostics ----
#
# Violations for the top-level shape of the claims object. Submodule
# violations live in the submodule's own .rego file and are unioned into
# `all_violations` below. See Docs/RegoPolicyGuide.md for the
# is_valid + violation sidecar contract.

violation contains "claims.output is missing" if {
	not claims.output
}

violation contains "claims.output.publicKey is null" if {
	claims.output
	claims.output.publicKey == null
}

violation contains "claims.output.expiration is null" if {
	claims.output
	claims.output.expiration == null
}

violation contains "claims.workloadTDX is missing" if {
	not claims.workloadTDX
}

violation contains "claims.workloadCCEL is missing" if {
	not claims.workloadCCEL
}

violation contains "claims.workloadCSEL is missing" if {
	not claims.workloadCSEL
}

violation contains "claims.keyProtectionTDX is missing" if {
	not claims.keyProtectionTDX
}

violation contains "claims.keyProtectionCCEL is missing" if {
	not claims.keyProtectionCCEL
}

# Cross-module aggregation. `opa build --target plan` does dead-code
# elimination and drops cross-package partial-set rules from the IR plan
# unless every rule on the call path carries `# METADATA / # entrypoint: true`
# — including this aggregation rule itself, otherwise the per-module
# `violation` calls behind it are pruned and the array reaches `decision`
# empty. Set union (`|`) auto-dedups; sort() makes the emitted array
# deterministic so logs and tests can pin specific messages.

# METADATA
# entrypoint: true
package_violations := {v | some v in violation}

# METADATA
# entrypoint: true
binding_violations := {v | some v in binding.violation}

# METADATA
# entrypoint: true
host_violations := {v | some v in host.violation}

# METADATA
# entrypoint: true
keyprotection_violations := {v | some v in keyprotection.violation}

# METADATA
# entrypoint: true
metadata_violations := {v | some v in metadata.violation}

# METADATA
# entrypoint: true
platformcertificate_violations := {v | some v in platformcertificate.violation}

# METADATA
# entrypoint: true
transparency_violations := {v | some v in transparency.violation}

# METADATA
# entrypoint: true
workload_violations := {v | some v in workload.violation}

# METADATA
# entrypoint: true
all_violations := ((((((package_violations | binding_violations) | host_violations) | keyprotection_violations) | metadata_violations) | platformcertificate_violations) | transparency_violations) | workload_violations

# METADATA
# entrypoint: true
decision := {
	"allow": valid[environment] == true,
	"violations": sort([v | some v in all_violations]),
}
