# Copyright © 2025 Apple Inc. All Rights Reserved.

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

package policy.main

import rego.v1

import data.policy.common.has_key

default is_valid := false

# version used for enforcing policies can be overriden with input version, must be at least min
min_enforced_version := 9
default version := 9
# we set requested version to whatever is in first config and check for conflicts later
requested_version := input["darwin-init"][0]["config_security_policy"]["version"]
version := requested_version if requested_version >= min_enforced_version

is_valid if {
	count(errors) == 0
}

# environment is used to determine which policy set to evaluate
default environment := "customer"

# we set policy to whatever is in first config and check for conflicts later
environment := input["darwin-init"][0]["config_security_policy"]["policy"]

# Collect all issues from the policy-specific rules
all_issues contains issue if {
	issue := data.policy[environment].deny[_]
}

# Add main-level issues (policy/version conflicts)
all_issues contains issue if {
    issue := main_issues[_]
}

# METADATA
# title: deny if config_security_policy.policy settings conflict in array
# custom:
#   key: config_security_policy.policy
main_issues contains issue if {
    i > 0
    config := input["darwin-init"][i]
    has_key(config.config_security_policy, "policy")
    msg := sprintf("%s may only be specified in config 0 (found in config %d)",
                   [rego.metadata.rule().custom.key, i])

    issue := {
        "index": i,
        "key": rego.metadata.rule().custom.key,
        "message": msg,
        "version": min_enforced_version
    }
}

# METADATA
# title: deny if config_security_policy.version settings conflict in array
# custom:
#   key: config_security_policy.version
main_issues contains issue if {
    i > 0
    config := input["darwin-init"][i]
    has_key(config.config_security_policy, "version")
    msg := sprintf("%s may only be specified in config 0 (found in config %d)",
                   [rego.metadata.rule().custom.key, i])

    issue := {
        "index": i,
        "key": rego.metadata.rule().custom.key,
        "message": msg,
        "version": min_enforced_version
    }
}

# METADATA
# title: deny if config_security_policy.version is lower than enforced min
# custom:
#  key: config_security_policy.version
main_issues contains issue if {
	requested_version < min_enforced_version
    msg := sprintf("%s must be greater than or equal to the latest approved version: %d",
                   [rego.metadata.rule().custom.key, min_enforced_version])

    issue := {
        "index": 0,  # Version is only checked in config 0
        "key": rego.metadata.rule().custom.key,
        "message": msg,
        "version": min_enforced_version
    }
}

# METADATA
# title: unknown environment
# custom:
#  key: config_security_policy.policy
main_issues contains issue if {
	not environment in {"customer", "carry", "customerProxy"}
	msg := sprintf("unknown security environment: %s", [environment])

    issue := {
        "index": 0,  # Policy is only in config 0
        "key": rego.metadata.rule().custom.key,
        "message": msg,
        "version": version
    }
}

# Build warnings dictionary: {index: {key: message}}
warnings := {warn_index: warn_key_messages |
    # Get all warning issues
    warn_index_issues := [issue |
        issue := all_issues[_]
        issue.version > version
        issue.index >= 0
    ]

    # Group by index - only iterates over indices that actually have issues
    warn_idx := warn_index_issues[_].index
    warn_index := warn_idx

    # Build key->message map for this index
    warn_key_messages := {key: msg |
        issue := warn_index_issues[_]
        issue.index == warn_index
        key := issue.key
        msg := issue.message
    }
}

# Build errors dictionary: {index: {key: message}}
errors := {err_index: err_key_messages |
    # Get all error issues
    err_index_issues := [issue |
        issue := all_issues[_]
        issue.version <= version
        issue.index >= 0
    ]

    # Group by index - only iterates over indices that actually have issues
    err_idx := err_index_issues[_].index
    err_index := err_idx

    # Build key->message map for this index
    err_key_messages := {key: msg |
        issue := err_index_issues[_]
        issue.index == err_index
        key := issue.key
        msg := issue.message
    }
}

# METADATA
# entrypoint: true
validate := {
	"is_valid": is_valid,
	"warnings": warnings,
	"errors": errors,
	"net_secure_config": data.policy[environment].net_secure_config
}
