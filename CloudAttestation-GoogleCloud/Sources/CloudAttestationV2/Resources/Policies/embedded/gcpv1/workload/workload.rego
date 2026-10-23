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

package gcpv1.workload

import data.gcpv1.confidentialvm

claims := input.claims

default vm_valid := false

# Overall VM validity
vm_valid if {
	confidentialvm.validate(
		claims.workloadTDX,
		claims.workloadCCEL,
		claims.protobuf.workloadReportDataDigest,
	)
}

# Workload container validity
default container_valid := false

container_valid if {
	vm_valid
	claims.workloadCSEL.containerImageDigest != null
}

default valid := false

valid if {
	vm_valid
	container_valid
	gpus_valid
}

# ---- Workload diagnostics ----
#
# These mirror the per-VM violations from the pre-refactor monolithic policy.
# `confidentialvm` cannot host them (its rules are parameterized helper
# functions and can't coexist with `violation contains ...` in the same head),
# so workload and keyprotection each duplicate the prefix-bearing variants.
#
# The METADATA entrypoint annotation is **required** so `opa build --target plan`
# emits this partial-rule function into the IR plan; without it, references
# from other packages (e.g. `gcpv1.all_violations`) silently compile to a
# no-op and the aggregated `decision.violations` array is always empty.

# METADATA
# entrypoint: true
violation contains "workloadTDX.reportData does not match protobuf.workloadReportDataDigest" if {
	claims.workloadTDX.reportData != claims.protobuf.workloadReportDataDigest
}

violation contains "workloadTDX not verified" if {
	claims.workloadTDX
	claims.workloadTDX.verified != true
}

violation contains "workloadCCEL.replayedRTMR0 does not match workloadTDX.rtmr0" if {
	claims.workloadTDX.rtmr0 != claims.workloadCCEL.replayedRTMR0
}

violation contains "workloadCCEL.replayedRTMR1 does not match workloadTDX.rtmr1" if {
	claims.workloadTDX.rtmr1 != claims.workloadCCEL.replayedRTMR1
}

violation contains "workloadCCEL.replayedRTMR2 does not match workloadTDX.rtmr2" if {
	claims.workloadTDX.rtmr2 != claims.workloadCCEL.replayedRTMR2
}

violation contains "workloadCCEL.secureBoot.uefiDebugMode is enabled" if {
	claims.workloadCCEL.secureBoot.uefiDebugMode == true
}

violation contains "workloadCCEL.secureBoot.dmaProtectionDisabled is true" if {
	claims.workloadCCEL.secureBoot.dmaProtectionDisabled == true
}

# Boot chain shape — accept Bowcaster (1 EFI app) or Vanguard (2 EFI apps).
violation contains msg if {
	claims.workloadCCEL.efiApplications
	not confidentialvm.bowcaster_boot_chain(claims.workloadCCEL)
	not confidentialvm.vanguard_boot_chain(claims.workloadCCEL)
	msg := sprintf(
		"workloadCCEL.efiApplications expected 1 (Bowcaster) or 2 (Vanguard) entries, got %d",
		[count(claims.workloadCCEL.efiApplications)],
	)
}

violation contains "workloadCCEL.kernel is null in Vanguard boot chain" if {
	confidentialvm.vanguard_boot_chain(claims.workloadCCEL)
	claims.workloadCCEL.kernel == null
}
